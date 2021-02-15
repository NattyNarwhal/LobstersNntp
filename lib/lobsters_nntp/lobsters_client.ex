defmodule LobstersNntp.LobstersClient do
  @moduledoc """
  Talks to Lobsters and puts stories and comments into Mnesia,
  additionally creating any NNTP marking as needed.
  """
  require Logger
  use GenServer
  # for more elixir idiomatic queries in mnesia
  require LobstersNntp.LobstersMnesia.Article
  require Exquisite
  use Amnesia

  defp newest_endpoint() do
    "https://#{Application.get_env(:lobsters_nntp, :domain)}/newest.json"
  end

  defp story_endpoint(short_id) do
    "https://#{Application.get_env(:lobsters_nntp, :domain)}/s/#{short_id}.json"
  end

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, [name: __MODULE__])
  end

  def init(args) do
    timer = schedule_update()
    {:ok, Map.put(args, :timer, timer)}
  end

  defp transform_story(story_map) do
    Logger.info("[CLI] Transforming story #{Map.get(story_map, "short_id")}")
    {:ok, ndt} = Map.get(story_map, "created_at")
                 |> NaiveDateTime.from_iso8601
    %LobstersNntp.LobstersMnesia.Story{
      id: Map.get(story_map, "short_id"),
      created_at: ndt,
      title: Map.get(story_map, "title"),
      url: Map.get(story_map, "url"),
      text: Map.get(story_map, "description"),
      karma: Map.get(story_map, "score"),
      tags: Map.get(story_map, "tags"),
      username: Map.get(story_map, "submitter_user") |> Map.get("username"),
    }
  end

  defp insert_story(story) do
    Logger.info("[CLI] Inserting story #{Map.get(story, :id)}")
    case LobstersNntp.LobstersMnesia.Story.read(story) do
      nil -> nil
      %LobstersNntp.LobstersMnesia.Story{} ->
        # Avoid dupes
        LobstersNntp.LobstersMnesia.Story.delete(story)
    end
    LobstersNntp.LobstersMnesia.Story.write(story)
    # only create new articles if the object didn't exist already
    # otherwise there are dupes
    article = %LobstersNntp.LobstersMnesia.Article{
      type: :story,
      obj_id: story.id
    }
    article_match = [type: :story, obj_id: story.id]
    case LobstersNntp.LobstersMnesia.Article.match(article_match) do
      nil ->
        Logger.info("[CLI] Creating article")
        LobstersNntp.LobstersMnesia.Article.write(article)
      _ ->
        # technically %Amnesia.Table.Match{values: [...]}
        Logger.info("[CLI] Already inserted article")
        :already_inserted
    end
  end

  defp transform_comment(comment_map) do
    Logger.info("[CLI] Transforming comment #{Map.get(comment_map, "short_id")}")
    {:ok, ndt} = Map.get(comment_map, "created_at")
                 |> NaiveDateTime.from_iso8601
    %LobstersNntp.LobstersMnesia.Comment{
      id: Map.get(comment_map, "short_id"),
      created_at: ndt,
      # this is an atom - we made it
      reply_to: Map.get(comment_map, :reply_to),
      story_id: Map.get(comment_map, :story_id),
      text: Map.get(comment_map, "comment"),
      karma: Map.get(comment_map, "score"),
      username: Map.get(comment_map, "commenting_user") |> Map.get("username"),
    }
  end

  defp insert_comment(comment) do
    Logger.info("[CLI] Transforming comment #{Map.get(comment, :id)}")
    case LobstersNntp.LobstersMnesia.Comment.read(comment) do
      nil -> nil
      %LobstersNntp.LobstersMnesia.Comment{} ->
        # Avoid dupes
        LobstersNntp.LobstersMnesia.Comment.delete(comment)
    end
    LobstersNntp.LobstersMnesia.Comment.write(comment)
    # only create new articles if the object didn't exist already
    # otherwise there are dupes
    article = %LobstersNntp.LobstersMnesia.Article{
      type: :comment,
      obj_id: comment.id
    }
    article_match = [type: :comment, obj_id: comment.id]
    case LobstersNntp.LobstersMnesia.Article.match(article_match) do
      nil ->
        Logger.info("[CLI] Creating article")
        LobstersNntp.LobstersMnesia.Article.write(article)
      _ ->
        # technically %Amnesia.Table.Match{values: [...]}
        Logger.info("[CLI] Already inserted article")
        :already_inserted
    end
  end

  defp mark_parents(%{"indent_level" => 1} = comment, previous_comments) do
    new_comment = comment
                  |> Map.put(:reply_to, nil)
    previous_comments ++ [new_comment]
  end

  defp mark_parents(comment, previous_comments) do
    cur_indent = Map.get(comment, "indent_level")
    last_appropriate = previous_comments
                       |> Enum.filter(fn comment -> Map.get(comment, "indent_level") == (cur_indent - 1) end)
                       |> List.last
                       |> Map.get("short_id")
    new_comment = comment
                  |> Map.put(:reply_to, last_appropriate)
    previous_comments ++ [new_comment]
  end

  defp get_comments(story) do
    short_id = Map.get(story, "short_id")
    Logger.info("[CLI] Getting comments for story #{short_id}")
    story_url = story_endpoint(short_id)
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} =
      HTTPoison.get(story_url)
    {:ok, %{"comments" => comments}} = Poison.decode(body)
    # The parenting isn't by ID, but by indent level.
    # How confusing! Since we need to accomodate for prior state,
    # we'll have to reduce and treat it like a map.
    comments
    |> Enum.map(fn comment -> Map.put(comment, :story_id, short_id) end)
    |> Enum.reduce([], &mark_parents/2)
  end

  def handle_cast(:update_articles, state) do
    Logger.info("[CLI] Updating articles")
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} =
      HTTPoison.get(newest_endpoint())
    {:ok, decoded_stories} = Poison.decode(body)
    comments = decoded_stories
               |> Enum.map(&get_comments/1)
    Amnesia.transaction do
      decoded_stories
      |> Enum.map(&transform_story/1)
      |> Enum.map(&insert_story/1)
      comments
      |> List.flatten # because it's a list of list of comments
      |> Enum.map(&transform_comment/1)
      |> Enum.map(&insert_comment/1)
    end
    Logger.info("[CLI] Done updating articles")
    {:noreply, state}
  end

  def handle_info(:update_articles, state) do
    update_articles()
    # because the scheduled job doesn't do GenServer stuff
    timer = schedule_update()
    {:noreply, Map.put(state, :timer, timer)}
  end

  defp schedule_update do
    # One hour
    Process.send_after(self(), :update_articles, 1 * 60 * 60 * 1000)
  end

  def update_articles, do: GenServer.cast(__MODULE__, :update_articles)
end
