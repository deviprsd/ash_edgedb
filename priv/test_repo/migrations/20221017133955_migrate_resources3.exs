defmodule AshEdgeDB.TestRepo.Migrations.MigrateResources3 do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_edgedb.generate_migrations`
  """

  use Ecto.Migration

  def up do
    create unique_index(:post_links, [:source_post_id, :destination_post_id],
             name: "post_links_unique_link_index"
           )
  end

  def down do
    drop_if_exists unique_index(:post_links, [:source_post_id, :destination_post_id],
                     name: "post_links_unique_link_index"
                   )
  end
end
