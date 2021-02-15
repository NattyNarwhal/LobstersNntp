defmodule LobstersNntp.NntpSession do
  require Logger
  use GenServer

  def start_link(socket, opts \\ []) do
    GenServer.start_link(__MODULE__, socket, opts)
  end

  def init(socket) do
    Logger.info("[TCP] Initialized")
    send_line(socket, "200 ready")
    {:ok, %{socket: socket, selected: nil}}
  end

  # NNTP protocol
  defp water_marks() do
    count = LobstersNntp.LobstersMnesia.Article.count()
    high = count
    low = if count > 0 do 1 else 0 end # should be first item
    {count, high, low}
  end

  defp nntp_list(socket, state) do
    send_line(socket, "215 Try the lobster")
    # Return format is group.name high low posting_allowed (y/n/m)
    {count, high, low} = water_marks()
    send_line(socket, "lobsters #{count} #{low} #{high} n");
    send_line(socket, ".")
    state
  end

  defp calculate_xover_range("<c_" <> rest) do
    {:comment, String.replace_suffix(rest, "@lobste.rs>", "")}
  end

  defp calculate_xover_range("<s_" <> rest) do
    {:story, String.replace_suffix(rest, "@lobste.rs>", "")}
  end

  defp calculate_xover_range(rest) do
    case String.split(rest, "-") do
      [first, ""] ->
        {int, _} = Integer.parse(first)
        {:articles_from, int}
      [first, last] ->
        {first_int, _} = Integer.parse(first)
        {last_int, _} = Integer.parse(last)
        {:articles_from_to, first_int, last_int}
      [article] ->
        {int, _} = Integer.parse(article)
        {:article, int}
      _ ->
        :error
    end
  end

  defp nntp_xover_range(socket, xover_arg) do
    case LobstersNntp.MboxWorker.xover(xover_arg) do
      nil ->
        send_line(socket, "423 Not in range")
      xover_lines ->
        send_line(socket, "224 Overview follows")
        Enum.map(xover_lines, fn line -> send_line(socket, line) end)
        send_line(socket, ".")
    end
  end

  defp nntp_xover(socket, state, range) do
    # 412 if !selected (only if range isn't an article id)
    case calculate_xover_range(range) do
      {type, _id} = xover_arg when type in [:story, :comment] ->
        case LobstersNntp.MboxWorker.xover(xover_arg) do
          nil ->
            send_line(socket, "430 No such comment")
          xover_line ->
            send_line(socket, "224 Overview follows")
            send_line(socket, xover_line)
            send_line(socket, ".")
        end
      {:articles_from, _from} = xover_arg ->
        nntp_xover_range(socket, xover_arg)
      {:articles_from_to, _from, _to} = xover_arg ->
        nntp_xover_range(socket, xover_arg)
      {:article, _article} = xover_arg ->
        nntp_xover_range(socket, xover_arg)
      _ ->
        send_line(socket, "501 Invalid range")
    end
    state
  end

  defp nntp_article(socket, state, article) do
    args = calculate_xover_range(article)
    result = case args do
      {type, _id} when type in [:story, :comment] ->
        LobstersNntp.MboxWorker.article(args)
      {:article, _article} ->
        LobstersNntp.MboxWorker.article(args)
      _ ->
        :error
    end
    case result do
      :error ->
        send_line(socket, "501 Invalid article")
        state
      nil ->
        case args do
          {:article, _article} ->
            send_line(socket, "423 No article with that number")
          {type, _id} when type in [:story, :comment] ->
            send_line(socket, "430 No article with that message-id")
        end
        state
      lines when is_list(lines) ->
        case args do
          {:article, article} ->
            # Oops, we should actually return structured data from mbox trans,
            # then actually convert THAT to Mbox
            message_id = lines
                         |> Enum.find_value(fn
                           "Message-ID: " <> id -> id;
                           _ -> nil end)
            send_line(socket, "220 #{article} #{message_id}")
          {:comment, id} ->
            send_line(socket, "220 0 <c_#{id}@lobste.rs>")
          {:story, id} ->
            send_line(socket, "220 0 <s_#{id}@lobste.rs>")
        end
        Enum.map(lines, fn line -> send_line(socket, line) end)
        send_line(socket, ".")
        Map.put(state, :selected_article, args)
    end
  end

  # TCP
  defp send_line(socket, line) do
    Logger.info("[S] " <> line)
    :gen_tcp.send(socket, line <> "\r\n")
  end
  
  def handle_info({:tcp, socket, data_newline}, state) do
    data = String.trim_trailing(data_newline)
    Logger.info("[C] " <> data)
    return = case data do
      "MODE READER"->
        # Return 200 when we become r/w
        send_line(socket, "201 LobstersNntp Ready, posting prohibited")
        {:noreply, Map.put(state, :mode, :reader)}
      "mode reader" ->
        # MicroPlanet Gravity does this in lowercase for some reason
        send_line(socket, "201 LobstersNntp Ready, posting prohibited")
        {:noreply, Map.put(state, :mode, :reader)}
      "XOVER " <> range ->
        {:noreply, nntp_xover(socket, state, range)}
      "OVER " <> range ->
        {:noreply, nntp_xover(socket, state, range)}
      "ARTICLE " <> article ->
        {:noreply, nntp_article(socket, state, article)}
      "LIST" ->
        {:noreply, nntp_list(socket, state)}
      "NEWGROUPS " <> _newgroups_args ->
        # not right, but it doesn't matter
        {:noreply, nntp_list(socket, state)}
      "GROUP lobsters" ->
        new_state = state
                    |> Map.put(:selected, :lobsters)
        {count, high, low} = water_marks()
        send_line(socket, "211 #{count} #{low} #{high} lobsters")
        {:noreply, new_state}
      "GROUP " <> _group ->
        send_line(socket, "411 Only use lobsters")
        {:noreply, state}
      "QUIT" ->
        Logger.info("[TCP] Exiting from QUIT")
        send_line(socket, "205 bye")
        :gen_tcp.close(socket)
        {:noreply, state}
      _ ->
        send_line(socket, "500 Huh?")
        {:noreply, state}
    end
    return
  end

  def handle_info({:tcp_closed, _socket}, _state) do
    Logger.info("[TCP] Exiting from socket close")
    Process.exit(self(), :normal)
  end
end
