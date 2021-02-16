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

  defp transform_article_range({_, article_number, id, :story}, opts) do
      Logger.info("[WRK] Article number #{article_number} corresponds to story #{id}")
      {head, body} = LobstersNntp.LobstersMnesia.Story.read(id)
                     |> Enum.map(fn x -> LobstersNntp.MboxTransform.transform(x, opts) end)
                     |> List.first
      {article_number, head, body}
  end

  defp transform_article_range({_, article_number, id, :comment}, opts) do
      Logger.info("[WRK] Article number #{article_number} corresponds to comment #{id}")
      {head, body} = LobstersNntp.LobstersMnesia.Comment.read(id)
                     |> Enum.map(fn x -> LobstersNntp.MboxTransform.transform(x, opts) end)
                     |> List.first
      {article_number, head, body}
  end

  def handle_call({:articles_from_to, from, to, opts}, _pid, state) do
    Logger.info("[WRK] Begin ARTICLE from #{from} to #{to}")
    articles = Amnesia.transaction do
      case LobstersNntp.LobstersMnesia.Article.where(id >= from and id <= to) do
        nil ->
          Logger.info("[WRK] No articles")
          []
        %Amnesia.Table.Select{values: articles} ->
          Logger.info("[WRK] Got #{Enum.count(articles)}")
          Enum.map(articles, fn x -> transform_article_range(x, opts) end)
      end
    end
    {:reply, articles, state}
  end

  def handle_call({:article, :comment, id, opts}, _pid, state) do
    Logger.info("[WRK] Begin ARTICLE for comment #{id}")
    [article | _] = Amnesia.transaction do
      LobstersNntp.LobstersMnesia.Comment.read(id)
      |> Enum.map(fn x -> LobstersNntp.MboxTransform.transform(x, opts) end)
    end
    {:reply, article, state}
  end

  def handle_call({:article, :story, id, opts}, _pid, state) do
    Logger.info("[WRK] Begin ARTICLE for story #{id}")
    [article | _] = Amnesia.transaction do
      LobstersNntp.LobstersMnesia.Story.read(id)
      |> Enum.map(fn x -> LobstersNntp.MboxTransform.transform(x, opts) end)
    end
    {:reply, article, state}
  end

  def handle_call({:article, :article, id, opts}, _pid, state) do
    Logger.info("[WRK] Begin ARTICLE for article number #{id}")
    [article | _] = Amnesia.transaction do
      returned_article = LobstersNntp.LobstersMnesia.Article.read(id)
      case returned_article do
        nil -> nil
        %LobstersNntp.LobstersMnesia.Article{} = article_obj ->
          LobstersNntp.LobstersMnesia.Article.get_original(article_obj)
      end
      |> Enum.map(fn x -> LobstersNntp.MboxTransform.transform(x, opts) end)
    end
    {:reply, article, state}
  end

  def article({type, id}, opts \\ %{}) when type in [:story, :comment, :article], do: GenServer.call(__MODULE__, {:article, type, id, opts})
  def articles(range, opts \\ %{})
  def articles({:articles_from, id}, opts), do: GenServer.call(__MODULE__, {:articles_from_to, id, 2_147_483_647, opts})
  def articles({:articles_from_to, from, to}, opts), do: GenServer.call(__MODULE__, {:articles_from_to, from, to, opts})
end
