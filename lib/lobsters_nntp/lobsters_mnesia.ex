use Amnesia

defdatabase LobstersNntp.LobstersMnesia do
  #deftable Tag, [:tag, :description], type: :bag do
  #  @type t :: %Tag{tag: String.t, description: String.t}
  #end

  deftable Story, [:id, :created_at, :title, :url, :text, :username, :tags, :karma], type: :bag do
    
  end

  deftable Comment, [:id, :created_at, :story_id, :reply_to, :text, :username, :karma], type: :bag do
    
  end

  # Each newsgroup requires its own article numbering, which is dumb
  # So for now, we only do one newsgroup. It's all anyone needs, right?
  # :obj_id should be [cs]_<short_id>
  # :id is the NNTP article number incrementing on order of arrival)
  # :type is :story or :comment
  deftable Article, [{:id, autoincrement}, :obj_id, :type], type: :ordered_set do
    def get_original(%{type: :story, obj_id: story_id}) do
      Story.read(story_id)
    end

    def get_original(%{type: :comment, obj_id: story_id}) do
      Comment.read(story_id)
    end

    def get_original!(%{type: :story, obj_id: story_id}) do
      Story.read!(story_id)
    end

    def get_original!(%{type: :comment, obj_id: story_id}) do
      Comment.read!(story_id)
    end
  end
end
