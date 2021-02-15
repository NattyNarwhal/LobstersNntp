defmodule LobstersNntp.MboxTransform do
  @moduledoc """
  Converts between Mnesia-stored records and NNTP formats like mbox.
  """
  require Logger

  defp date_format(ndt) do
    date = ndt.day
    month = case ndt.month do
      1 -> "Jan"
      2 -> "Feb"
      3 -> "Mar"
      4 -> "Apr"
      5 -> "May"
      6 -> "Jun"
      7 -> "Jul"
      8 -> "Aug"
      9 -> "Sep"
      10 -> "Oct"
      11 -> "Nov"
      12 -> "Dec"
    end
    year = ndt.year
    time = NaiveDateTime.to_time(ndt)
           |> Time.truncate(:second)
           |> Time.to_string
    # the TZ is wrong because NDT. lobsters runs central time
    "#{date} #{month} #{year} #{time} #{Application.get_env(:lobsters_nntp, :tz)}"
  end

  defp escape_body(body_string) do
    # XXX: Word wrap to 72 or something, and UTF-8ification
    # For now, just make sure any lines are separate,
    # and there is no termination character
    String.split(body_string, ~r{\r?\n})
    |> Enum.map(fn "." -> ".."; x -> x end)
  end

  def reference(%LobstersNntp.LobstersMnesia.Comment{reply_to: nil, story_id: story_id}) do
    "s_#{story_id}"
  end

  def reference(%LobstersNntp.LobstersMnesia.Comment{reply_to: reply_to}) do
    "c_#{reply_to}"
  end

  def subject(%LobstersNntp.LobstersMnesia.Story{title: title}) do
    title
  end

  def subject(%LobstersNntp.LobstersMnesia.Comment{story_id: story_id}) do
    # This is probably better done in the worker, but for now, everything
    # calling this is done in the Mnesia transaction
    [%LobstersNntp.LobstersMnesia.Story{title: title} | _] =
      LobstersNntp.LobstersMnesia.Story.read(story_id)
    "Re: #{title}"
  end

  defp from(%{username: username}) do
    "\"#{username}\" <#{username}@#{Application.get_env(:lobsters_nntp, :domain)}>"
  end

  def create_headers(%LobstersNntp.LobstersMnesia.Story{} = story) do
    fake_newsgroups = story.tags
                      |> Enum.map(fn tag -> "lobsters.tag.#{tag}" end)
                      |> Enum.join(", ")
    [
      "Subject: #{subject(story)}",
      "From: #{from(story)}",
      "Date: #{date_format(story.created_at)}",
      "Message-ID: <s_#{story.id}@#{Application.get_env(:lobsters_nntp, :domain)}>",
      "Newsgroups: lobsters, #{fake_newsgroups}",
      "Path: lobsters!nntp",
      "X-Lobsters: \"https://#{Application.get_env(:lobsters_nntp, :domain)}/s/#{story.id}\"",
      "X-Lobsters-Karma: #{story.karma}",
      "Content-Type: text/html; charset=UTF-8"
    ]
  end

  def create_headers(%LobstersNntp.LobstersMnesia.Comment{} = comment) do
    reference_id = reference(comment)
    [
      # XXX: Store the story title (or fetch it)
      "Subject: #{subject(comment)}",
      "From: #{from(comment)}",
      "Date: #{date_format(comment.created_at)}",
      "Message-ID: <c_#{comment.id}@#{Application.get_env(:lobsters_nntp, :domain)}>",
      "References: <#{reference_id}@#{Application.get_env(:lobsters_nntp, :domain)}>",
      "Newsgroups: lobsters",
      "Path: lobsters!nntp",
      "X-Lobsters: \"https://#{Application.get_env(:lobsters_nntp, :domain)}/c/#{comment.id}\"",
      "X-Lobsters-Karma: #{comment.karma}",
      "Content-Type: text/html; charset=UTF-8"
    ]
  end

  def create_body(%LobstersNntp.LobstersMnesia.Story{} = story) do
    # XXX: is some of the metadata (like tags) better in the header?
    case story.url do
      "" ->
        []
      url ->
        ["URL: #{url}", ""]
    end ++ case story.text do
      "" ->
        []
      text ->
        escape_body(text) ++ [""]
    end
  end

  def create_body(%LobstersNntp.LobstersMnesia.Comment{} = comment) do
    escape_body(comment.text)
  end

  # Each string in the list is a line
  def transform(%LobstersNntp.LobstersMnesia.Story{} = story) do
    headers = create_headers(story)
    body = create_body(story)
    {headers, body}
  end

  def transform(%LobstersNntp.LobstersMnesia.Comment{} = comment) do
    headers = create_headers(comment)
    body = create_body(comment)
    {headers, body}
  end

  def transform(nil), do: nil
end
