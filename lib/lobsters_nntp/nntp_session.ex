defmodule LobstersNntp.NntpSession do
  require Logger
  use GenServer

  def start_link(socket, opts \\ []) do
    GenServer.start_link(__MODULE__, socket, opts)
  end

  def init(socket) do
    Logger.info("[TCP] Initialized")
    send_line(socket, "200 ready")
    state = %{
      socket: socket,
      selected: nil,
      content_type: :multipart
    }
    {:ok, state}
  end

  # NNTP protocol
  defp extract_header_items(headers, header) do
    headers
    |> Enum.filter(fn x -> String.starts_with?(x, header) end)
    |> Enum.map(fn x -> String.replace_prefix(x, header <> ": ", "") end)
  end

  defp extract_header_item(headers, header) do
    case extract_header_items(headers, header) do
      [] ->
        nil
      [first | _] when is_binary(first) ->
        first
    end
  end

  defp water_marks() do
    count = LobstersNntp.LobstersMnesia.Article.count()
    high = count
    low = if count > 0 do 1 else 0 end # should be first item
    {count, high, low}
  end

  defp nntp_list(socket, state, type \\ :active) do
    case type do
      :new ->
        send_line(socket, "231 All groups have same content but different format")
      _ ->
        send_line(socket, "215 All groups have same content but different format")
    end
    # Return format is group.name high low posting_allowed (y/n/m)
    {count, high, low} = water_marks()
    send_line(socket, "lobsters #{count} #{low} #{high} n");
    send_line(socket, "lobsters.plain #{count} #{low} #{high} n");
    send_line(socket, ".")
    state
  end

  defp calculate_range("<c_" <> rest) do
    [id | _] = String.split(rest, "@")
    {:comment, id}
  end

  defp calculate_range("<s_" <> rest) do
    [id | _] = String.split(rest, "@")
    {:story, id}
  end

  defp calculate_range(rest) do
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

  # art_num|subj|from|date|id|ref|bytes|lines
  defp nntp_xover_item({article_number, head, body}) do
    body_text = Enum.join(body, "\r\n")
    lines = Enum.count(body)
    bytes = byte_size(body_text)
    [
      "#{article_number}",
      "#{extract_header_item(head, "Subject")}",
      "#{extract_header_item(head, "From")}",
      "#{extract_header_item(head, "Date")}",
      "#{extract_header_item(head, "Message-ID")}",
      "#{extract_header_item(head, "References")}",
      "#{bytes}",
      "#{lines}"
    ] |> Enum.join("\t")
  end

  defp nntp_xover_range(socket, xover_arg, client_opts) do
    case LobstersNntp.MboxWorker.articles(xover_arg, client_opts) do
      nil ->
        send_line(socket, "423 Not in range")
      articles ->
        send_line(socket, "224 Overview follows")
        articles
        |> Enum.map(&nntp_xover_item/1)
        |> Enum.map(fn line -> send_line(socket, line) end)
        send_line(socket, ".")
    end
  end

  defp nntp_xover(socket, state, range) do
    client_opts = %{
      content_type: state.content_type
    }
    # 412 if !selected (only if range isn't an article id)
    case calculate_range(range) do
      {type, _id} = xover_arg when type in [:story, :comment] ->
        case LobstersNntp.MboxWorker.article(xover_arg, client_opts) do
          nil ->
            send_line(socket, "430 No such comment")
          {head, body} ->
            send_line(socket, "224 Overview follows")
            send_line(socket, nntp_xover_item({0, head, body}))
            send_line(socket, ".")
        end
      {:article, article} ->
        nntp_xover_range(socket, {:articles_from_to, article, article}, client_opts)
      {:articles_from, _from} = xover_arg ->
        nntp_xover_range(socket, xover_arg, client_opts)
      {:articles_from_to, _from, _to} = xover_arg ->
        nntp_xover_range(socket, xover_arg, client_opts)
      _ ->
        send_line(socket, "501 Invalid range")
    end
    state
  end

  defp nntp_article(socket, state, article, parts) do
    args = calculate_range(article)
    client_opts = %{
      content_type: state.content_type
    }
    result = case args do
      {type, _id} when type in [:story, :comment] ->
        LobstersNntp.MboxWorker.article(args, client_opts)
      {:article, _article} ->
        LobstersNntp.MboxWorker.article(args, client_opts)
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
      {header, body} ->
        message_id = extract_header_item(header, "Message-ID")
        article_number = case args do
          {:article, article} -> article
          _ -> 0
        end
        case parts do
          :article ->
            send_line(socket, "220 #{article_number} #{message_id}")
            Enum.map(header, fn line -> send_line(socket, line) end)
            send_line(socket, "") # spacing between header and body
            Enum.map(body, fn line -> send_line(socket, line) end)
            send_line(socket, ".")
          :headers ->
            send_line(socket, "221 #{article_number} #{message_id}")
            Enum.map(header, fn line -> send_line(socket, line) end)
            send_line(socket, ".")
          :body ->
            send_line(socket, "222 #{article_number} #{message_id}")
            Enum.map(body, fn line -> send_line(socket, line) end)
            send_line(socket, ".")
          :stat ->
            send_line(socket, "223 #{article_number} #{message_id}")
        end
        Map.put(state, :selected_article, args)
    end
  end

  defp nntp_group(socket, state, group) do
    {count, high, low} = water_marks()
    case group do
      "lobsters" ->
        send_line(socket, "211 #{count} #{low} #{high} lobsters")
        state
        |> Map.put(:selected, :lobsters)
        |> Map.put(:content_type, :multipart)
      "lobsters.plain" ->
        send_line(socket, "211 #{count} #{low} #{high} lobsters.plain")
        state
        |> Map.put(:selected, :lobsters)
        |> Map.put(:content_type, :plain)
      _ ->
        send_line(socket, "411 Only use lobsters")
        state
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
        {:noreply, nntp_article(socket, state, article, :article)}
      "HEAD " <> article ->
        {:noreply, nntp_article(socket, state, article, :headers)}
      "BODY " <> article ->
        {:noreply, nntp_article(socket, state, article, :body)}
      "STAT " <> article ->
        {:noreply, nntp_article(socket, state, article, :stat)}
      "LIST" ->
        {:noreply, nntp_list(socket, state)}
      "NEWGROUPS " <> _newgroups_args ->
        # not right, but it doesn't matter
        {:noreply, nntp_list(socket, state, :new)}
      "GROUP " <> group ->
        {:noreply, nntp_group(socket, state, group)}
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

  def handle_info({:tcp_error, _socket, error}, _state) do
    Logger.info("[TCP] Exiting from socket error (#{error})")
    Process.exit(self(), :normal)
  end

  def handle_info({:tcp_closed, _socket}, _state) do
    Logger.info("[TCP] Exiting from socket close")
    Process.exit(self(), :normal)
  end
end
