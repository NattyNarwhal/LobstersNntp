defmodule LobstersNntp.MboxWorker do
  @moduledoc """
  Handles commands for getting Mnesia data into NNTP formats.

  Conversions are implemented in MboxTransform.
  """
  require Logger
  use GenServer
  # for more elixir idiomatic queries in mnesia
  require LobstersNntp.LobstersMnesia.Article
  require Exquisite
  use Amnesia

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, [name: __MODULE__])
  end

  def init(args) do
    {:ok, args}
  end

  def handle_call({:xover, :story, story_id}, _pid, state) do
    story = Amnesia.transaction do
      LobstersNntp.LobstersMnesia.Story.read(story_id)
    end
    story_xover = case story do
      nil ->
        nil
      _story ->
        LobstersNntp.MboxTransform.xover(story)
    end
    {:reply, story_xover, state}
  end

  def handle_call({:xover, :comment, comment_id}, _pid, state) do
    story = Amnesia.transaction do
      LobstersNntp.LobstersMnesia.Comment.read(comment_id)
    end
    story_xover = case story do
      nil ->
        nil
      _story ->
        LobstersNntp.MboxTransform.xover(story)
    end
    {:reply, story_xover, state}
  end

  def handle_call({:xover, :articles_from_to, from, to}, _pid, state) do
    Logger.info("[WRK] Begin XOVER from #{from} to #{to}")
    xovers = Amnesia.transaction do
      case LobstersNntp.LobstersMnesia.Article.where(id >= from and id <= to) do
        nil ->
          Logger.info("[WRK] No articles")
          []
        %Amnesia.Table.Select{values: articles} ->
          Logger.info("[WRK] Got #{Enum.count(articles)}")
          Enum.map(articles, fn
            {_, article_number, id, :story} ->
              Logger.info("[WRK] Article number #{article_number} corresponds to story #{id}")
              # Why can multiple return?
              [obj | _] = LobstersNntp.LobstersMnesia.Story.read(id)
              {article_number, obj}
            {_, article_number, id, :comment} ->
              Logger.info("[WRK] Article number #{article_number} corresponds to comment #{id}")
              [obj | _] = LobstersNntp.LobstersMnesia.Comment.read(id)
              {article_number, obj}
          end)
      end
      |> Enum.map(fn {article_number, object} -> LobstersNntp.MboxTransform.xover(object, article_number) end)
    end
    {:reply, xovers, state}
  end

  def handle_call({:article, :comment, id}, _pid, state) do
    Logger.info("[WRK] Begin ARTICLE for comment #{id}")
    [article | _] = Amnesia.transaction do
      LobstersNntp.LobstersMnesia.Comment.read(id)
    end
    transformed = LobstersNntp.MboxTransform.transform(article)
    {:reply, transformed, state}
  end

  def handle_call({:article, :story, id}, _pid, state) do
    Logger.info("[WRK] Begin ARTICLE for story #{id}")
    [article | _] = Amnesia.transaction do
      LobstersNntp.LobstersMnesia.Story.read(id)
    end
    transformed = LobstersNntp.MboxTransform.transform(article)
    {:reply, transformed, state}
  end

  def handle_call({:article, :article, id}, _pid, state) do
    Logger.info("[WRK] Begin ARTICLE for article number #{id}")
    [article | _] = Amnesia.transaction do
      returned_article = LobstersNntp.LobstersMnesia.Article.read(id)
      case returned_article do
        nil -> nil
        %LobstersNntp.LobstersMnesia.Article{} = article_obj ->
          LobstersNntp.LobstersMnesia.Article.get_original(article_obj)
      end
    end
    transformed = LobstersNntp.MboxTransform.transform(article)
    {:reply, transformed, state}
  end

  def xover({type, story_id}) when type in [:story, :comment], do: GenServer.call(__MODULE__, {:xover, type, story_id})
  def xover({:article, article}), do: GenServer.call(__MODULE__, {:xover, :articles_from_to, article, article})
  def xover({:articles_from, from}), do: GenServer.call(__MODULE__, {:xover, :articles_from_to, from, 2_147_483_647})
  def xover({:articles_from_to, from, to}), do: GenServer.call(__MODULE__, {:xover, :articles_from_to, from, to})

  def article({type, id}) when type in [:story, :comment, :article], do: GenServer.call(__MODULE__, {:article, type, id})
end
