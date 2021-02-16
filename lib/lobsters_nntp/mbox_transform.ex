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

  defp qp_subject(subject) do
    [encoded] = :lobsters_nntp_mime.encode_quoted_printable(subject)
    # remove whitespace that can disrupt parsing
    # the question mark at the end causes fun parsing issues
    cleaned = String.replace(encoded, ~r{=?[\t\r\n]}, "")
              |> String.replace("?", "=3F")
    # Use ?B? for Base64
    "=?UTF-8?Q?#{cleaned}?="
  end

  defp body_to_lines(body_string) do
    String.split(body_string, ~r{\r?\n})
    |> Enum.map(fn "." -> ".."; x -> x end)
  end

  def html_to_encoded_text(html, strip_boundary \\ nil) do
    # XXX: hacky
    without_boundary = case strip_boundary do
      nil -> html
      _ -> String.replace(html, strip_boundary, "A" <> strip_boundary)
    end
    # TODO: We should instead of stripping, do some parsing.
    # (Unless Peter gives us raw Markdown... hmmm...)
    stripped = HtmlSanitizeEx.strip_tags(without_boundary)
    # Make this QP
    [encoded] = :lobsters_nntp_mime.encode_quoted_printable(stripped)
    encoded
  end

  def html_to_encoded_html(html, strip_boundary \\ nil) do
    without_boundary = case strip_boundary do
      nil -> html
      _ -> String.replace(html, strip_boundary, "A" <> strip_boundary)
    end
    [encoded] = :lobsters_nntp_mime.encode_quoted_printable(without_boundary)
    encoded
  end

  def multipart_from_html(text, boundary \\ "__LobstersNntpBoundary") do
    plain = html_to_encoded_text(text, boundary)
    html = html_to_encoded_html(text, boundary)
    """
    --#{boundary}
    Content-Type: text/plain; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    #{plain}
    
    
    --#{boundary}
    Content-Type: text/html; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    #{html}
    """
  end

  def reference(%LobstersNntp.LobstersMnesia.Comment{reply_to: nil, story_id: story_id}) do
    "s_#{story_id}"
  end

  def reference(%LobstersNntp.LobstersMnesia.Comment{reply_to: reply_to}) do
    "c_#{reply_to}"
  end

  def subject(%LobstersNntp.LobstersMnesia.Story{title: title}) do
    title |> qp_subject
  end

  def subject(%LobstersNntp.LobstersMnesia.Comment{story_id: story_id}) do
    # This is probably better done in the worker, but for now, everything
    # calling this is done in the Mnesia transaction
    [%LobstersNntp.LobstersMnesia.Story{title: title} | _] =
      LobstersNntp.LobstersMnesia.Story.read(story_id)
    "Re: #{title}" |> qp_subject
  end

  defp from(%{username: username}) do
    "\"#{username}\" <#{username}@#{Application.get_env(:lobsters_nntp, :domain)}>"
  end

  defp encoding(:multipart) do
    ["Content-Type: multipart/alternative; boundary=__LobstersNntpBoundary"]
  end

  defp encoding(:plain) do
    [
      "Content-Type: text/plain; charset=\"UTF-8\"",
      "Content-Transfer-Encoding: quoted-printable"
    ]
  end

  defp encoding(:html) do
    [
      "Content-Type: text/html; charset=\"UTF-8\"",
      "Content-Transfer-Encoding: quoted-printable"
    ]
  end

  def create_headers(%LobstersNntp.LobstersMnesia.Story{} = story, options) do
    fake_newsgroups = story.tags
                      |> Enum.map(fn tag -> "lobsters.tag.#{tag}" end)
                      |> Enum.join(", ")
    headers = [
      "Subject: #{subject(story)}",
      "From: #{from(story)}",
      "Date: #{date_format(story.created_at)}",
      "Message-ID: <s_#{story.id}@#{Application.get_env(:lobsters_nntp, :domain)}>",
      "Newsgroups: lobsters, #{fake_newsgroups}",
      "Path: lobsters!nntp",
      "X-Lobsters: \"https://#{Application.get_env(:lobsters_nntp, :domain)}/s/#{story.id}\"",
      "X-Lobsters-Karma: #{story.karma}",
    ] 
    headers ++ encoding(options.content_type)
  end

  def create_headers(%LobstersNntp.LobstersMnesia.Comment{} = comment, options) do
    reference_id = reference(comment)
    headers = [
      "Subject: #{subject(comment)}",
      "From: #{from(comment)}",
      "Date: #{date_format(comment.created_at)}",
      "Message-ID: <c_#{comment.id}@#{Application.get_env(:lobsters_nntp, :domain)}>",
      "References: <#{reference_id}@#{Application.get_env(:lobsters_nntp, :domain)}>",
      "Newsgroups: lobsters",
      "Path: lobsters!nntp",
      "X-Lobsters: \"https://#{Application.get_env(:lobsters_nntp, :domain)}/c/#{comment.id}\"",
      "X-Lobsters-Karma: #{comment.karma}",
    ]
    headers ++ encoding(options.content_type)
  end

  defp transform_text(html_text, options) do
    case options.content_type do
      :multipart ->
        multipart_from_html(html_text)
      :html ->
        html_to_encoded_html(html_text)
      :plain ->
        html_to_encoded_text(html_text)
    end
    |> body_to_lines
  end

  def create_body(%LobstersNntp.LobstersMnesia.Story{} = story, options) do
    # XXX: is some of the metadata (like tags) better in the header?
    html_text = case story.url do
      "" -> ""
      url -> "<p>URL: <a href=\"#{url}\">#{url}</a></p>\r\n\r\n"
    end <> story.text
    transform_text(html_text, options)
  end

  def create_body(%LobstersNntp.LobstersMnesia.Comment{} = comment, options) do
    html_text = comment.text
    transform_text(html_text, options)
  end

  # Each string in the list is a line
  def transform(object, options \\ %{})

  def transform(%LobstersNntp.LobstersMnesia.Story{} = story, options) do
    merged_options = Map.merge(%{
      content_type: :multipart
    }, options)
    headers = create_headers(story, merged_options)
    body = create_body(story, merged_options)
    {headers, body}
  end

  def transform(%LobstersNntp.LobstersMnesia.Comment{} = comment, options) do
    merged_options = Map.merge(%{
      content_type: :multipart
    }, options)
    headers = create_headers(comment, merged_options)
    body = create_body(comment, merged_options)
    {headers, body}
  end

  def transform(nil, _options), do: nil
end
