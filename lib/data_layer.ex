defmodule AshEdgeDB.DataLayer do

  alias Ash.Filter
  alias Ash.Query.{BooleanExpression, Not, Ref}

  @behaviour Ash.DataLayer

  def migrate(args) do
    # TODO: take args that we care about
    Mix.Task.run("ash_edgedb.migrate", args)
  end

  def codegen(args) do
    # TODO: take args that we care about
    Mix.Task.run("ash_edgedb.generate_migrations", args)
  end

  def setup(args) do
    # TODO: take args that we care about
    Mix.Task.run("ash_edgedb.create", args)
    Mix.Task.run("ash_edgedb.migrate", args)
    Mix.Task.run("ash_edgedb.migrate", ["--tenant" | args])
  end

  def tear_down(args) do
    # TODO: take args that we care about
    Mix.Task.run("ash_edgedb.drop", args)
  end

  import Ecto.Query, only: [from: 2, subquery: 1]

  @impl true
  def can?(_, :async_engine), do: false
  def can?(_, :bulk_create), do: false
  def can?(_, {:lock, :for_update}), do: false

  def can?(_, {:lock, string}), do: false
  #   string = String.trim_trailing(string, " NOWAIT")

  #   String.upcase(string) in [
  #     "FOR UPDATE",
  #     "FOR NO KEY UPDATE",
  #     "FOR SHARE",
  #     "FOR KEY SHARE"
  #   ]
  # end

  def can?(_, :transact), do: false
  def can?(_, :composite_primary_key), do: false
  def can?(_, {:atomic, :update}), do: false
  def can?(_, {:atomic, :upsert}), do: false
  def can?(_, :upsert), do: false
  def can?(_, :changeset_filter), do: false

  def can?(resource, {:join, other_resource}), do: false
  #   data_layer = Ash.DataLayer.data_layer(resource)
  #   other_data_layer = Ash.DataLayer.data_layer(other_resource)

  #   data_layer == other_data_layer and
  #     AshEdgeDB.DataLayer.Info.repo(resource, :read) ==
  #       AshEdgeDB.DataLayer.Info.repo(other_resource, :read)
  # end

  def can?(resource, {:lateral_join, resources}), do: false
  #   repo = AshEdgeDB.DataLayer.Info.repo(resource, :read)
  #   data_layer = Ash.DataLayer.data_layer(resource)

  #   data_layer == __MODULE__ &&
  #     Enum.all?(resources, fn resource ->
  #       Ash.DataLayer.data_layer(resource) == data_layer &&
  #         AshEdgeDB.DataLayer.Info.repo(resource, :read) == repo
  #     end)
  # end

  def can?(_, :boolean_filter), do: false

  def can?(_, {:aggregate, type})
      when type in [:count, :sum, :first, :list, :avg, :max, :min, :exists, :custom],
      do: false

  def can?(_, :aggregate_filter), do: false
  def can?(_, :aggregate_sort), do: false
  def can?(_, :expression_calculation), do: false
  def can?(_, :expression_calculation_sort), do: false
  def can?(_, :create), do: false
  def can?(_, :select), do: false
  def can?(_, :read), do: false

  def can?(resource, action) when action in ~w[update destroy]a, do: false
  #   resource
  #   |> Ash.Resource.Info.primary_key()
  #   |> Enum.any?()
  # end

  def can?(_, :filter), do: false
  def can?(_, :limit), do: false
  def can?(_, :offset), do: false
  def can?(_, :multitenancy), do: false

  def can?(_, {:filter_relationship, %{manual: {module, _}}}), do: false
  #   Spark.implements_behaviour?(module, AshEdgeDB.ManualRelationship)
  # end

  def can?(_, {:filter_relationship, _}), do: false

  def can?(_, {:aggregate_relationship, %{manual: {module, _}}}), do: false
  #   Spark.implements_behaviour?(module, AshEdgeDB.ManualRelationship)
  # end

  def can?(_, {:aggregate_relationship, _}), do: false

  def can?(_, :timeout), do: false
  def can?(_, {:filter_expr, _}), do: false
  def can?(_, :nested_expressions), do: false
  def can?(_, {:query_aggregate, _}), do: false
  def can?(_, :sort), do: false
  def can?(_, :distinct_sort), do: false
  def can?(_, :distinct), do: false
  def can?(_, {:sort, _}), do: false
  def can?(_, _), do: false

  @impl true
  def in_transaction?(resource) do
    AshEdgeDB.DataLayer.Info.repo(resource, :mutate).in_transaction?()
  end

  @impl true
  def limit(query, nil, _), do: {:ok, query}

  def limit(query, limit, _resource) do
    {:ok, from(row in query, limit: ^limit)}
  end

  @impl true
  def source(resource) do
    AshEdgeDB.DataLayer.Info.table(resource) || ""
  end

  @impl true
  def set_context(resource, data_layer_query, context) do
    start_bindings = context[:data_layer][:start_bindings_at] || 0
    data_layer_query = from(row in data_layer_query, as: ^start_bindings)

    data_layer_query =
      if context[:data_layer][:table] do
        %{
          data_layer_query
          | from: %{data_layer_query.from | source: {context[:data_layer][:table], resource}}
        }
      else
        data_layer_query
      end

    data_layer_query =
      if context[:data_layer][:schema] do
        Ecto.Query.put_query_prefix(data_layer_query, to_string(context[:data_layer][:schema]))
      else
        data_layer_query
      end

    data_layer_query =
      data_layer_query
      |> default_bindings(resource, context)

    case context[:data_layer][:lateral_join_source] do
      {_, [{%{resource: resource}, _, _, _} | rest]} ->
        parent =
          resource
          |> resource_to_query(nil)
          |> default_bindings(resource, context)

        parent =
          case rest do
            [{resource, _, _, %{name: join_relationship_name}} | _] ->
              binding_data = %{type: :inner, path: [join_relationship_name], source: resource}
              add_binding(parent, binding_data)

            _ ->
              parent
          end

        ash_bindings =
          data_layer_query.__ash_bindings__
          |> Map.put(:parent_bindings, Map.put(parent.__ash_bindings__, :parent?, true))
          |> Map.put(:parent_resources, [
            parent.__ash_bindings__.resource | parent.__ash_bindings__[:parent_resources] || []
          ])

        {:ok, %{data_layer_query | __ash_bindings__: ash_bindings}}

      _ ->
        {:ok, data_layer_query}
    end
  end

  @impl true
  def offset(query, nil, _), do: query

  def offset(%{offset: old_offset} = query, 0, _resource) when old_offset in [0, nil] do
    {:ok, query}
  end

  def offset(query, offset, _resource) do
    {:ok, from(row in query, offset: ^offset)}
  end

  @impl true
  def run_query(query, resource) do
    query = default_bindings(query, resource)

    with_sort_applied =
      if query.__ash_bindings__[:sort_applied?] do
        {:ok, query}
      else
        apply_sort(query, query.__ash_bindings__[:sort], resource)
      end

    case with_sort_applied do
      {:error, error} ->
        {:error, error}

      {:ok, query} ->
        query =
          if query.__ash_bindings__[:__order__?] && query.windows[:order] do
            if query.distinct do
              query_with_order =
                from(row in query, select_merge: %{__order__: over(row_number(), :order)})

              query_without_limit_and_offset =
                query_with_order
                |> Ecto.Query.exclude(:limit)
                |> Ecto.Query.exclude(:offset)

              from(row in subquery(query_without_limit_and_offset),
                select: row,
                order_by: row.__order__
              )
              |> Map.put(:limit, query.limit)
              |> Map.put(:offset, query.offset)
            else
              order_by = %{query.windows[:order] | expr: query.windows[:order].expr[:order_by]}

              %{
                query
                | windows: Keyword.delete(query.windows, :order),
                  order_bys: [order_by]
              }
            end
          else
            %{query | windows: Keyword.delete(query.windows, :order)}
          end

        if AshEdgeDB.DataLayer.Info.polymorphic?(resource) && no_table?(query) do
          raise_table_error!(resource, :read)
        else
          {:ok, dynamic_repo(resource, query).all(query, repo_opts(nil, nil, resource))}
        end
    end
  rescue
    e ->
      handle_raised_error(e, __STACKTRACE__, query, resource)
  end

  defp no_table?(%{from: %{source: {"", _}}}), do: true
  defp no_table?(_), do: false

  defp repo_opts(timeout, nil, resource) do
    if schema = AshEdgeDB.DataLayer.Info.schema(resource) do
      [prefix: schema]
    else
      []
    end
    |> add_timeout(timeout)
  end

  defp repo_opts(timeout, tenant, resource) do
    if Ash.Resource.Info.multitenancy_strategy(resource) == :context do
      [prefix: tenant]
    else
      if schema = AshEdgeDB.DataLayer.Info.schema(resource) do
        [prefix: schema]
      else
        []
      end
    end
    |> add_timeout(timeout)
  end

  defp add_timeout(opts, timeout) when not is_nil(timeout) do
    Keyword.put(opts, :timeout, timeout)
  end

  defp add_timeout(opts, _), do: opts

  @impl true
  def functions(resource) do
    config = AshEdgeDB.DataLayer.Info.repo(resource, :mutate).config()

    functions = [
      AshEdgeDB.Functions.Fragment,
      AshEdgeDB.Functions.Like,
      AshEdgeDB.Functions.ILike
    ]

    functions =
      if "pg_trgm" in (config[:installed_extensions] || []) do
        functions ++
          [
            AshEdgeDB.Functions.TrigramSimilarity
          ]
      else
        functions
      end

    if "vector" in (config[:installed_extensions] || []) do
      functions ++
        [
          AshEdgeDB.Functions.VectorCosineDistance
        ]
    else
      functions
    end
  end

  @impl true
  def run_aggregate_query(query, aggregates, resource) do
    {exists, aggregates} = Enum.split_with(aggregates, &(&1.kind == :exists))
    query = default_bindings(query, resource)

    query =
      if query.distinct || query.limit do
        query =
          query
          |> Ecto.Query.exclude(:select)
          |> Ecto.Query.exclude(:order_by)
          |> Map.put(:windows, [])

        from(row in subquery(query), as: ^0, select: %{})
      else
        query
        |> Ecto.Query.exclude(:select)
        |> Ecto.Query.exclude(:order_by)
        |> Map.put(:windows, [])
        |> Ecto.Query.select(%{})
      end

    query_before_select = query

    query =
      Enum.reduce(
        aggregates,
        query,
        fn agg, query ->
          first_relationship =
            Ash.Resource.Info.relationship(resource, agg.relationship_path |> Enum.at(0))

          AshEdgeDB.Aggregate.add_subquery_aggregate_select(
            query,
            agg.relationship_path |> Enum.drop(1),
            agg,
            resource,
            true,
            first_relationship
          )
        end
      )

    result =
      case aggregates do
        [] ->
          %{}

        _ ->
          dynamic_repo(resource, query).one(query, repo_opts(nil, nil, resource))
      end

    {:ok, add_exists_aggs(result, resource, query_before_select, exists)}
  end

  defp add_exists_aggs(result, resource, query, exists) do
    repo = dynamic_repo(resource, query)
    repo_opts = repo_opts(nil, nil, resource)

    Enum.reduce(exists, result, fn agg, result ->
      {:ok, filtered} =
        case agg do
          %{query: %{filter: filter}} when not is_nil(filter) ->
            filter(query, filter, resource)

          _ ->
            {:ok, query}
        end

      Map.put(
        result || %{},
        agg.name,
        repo.exists?(filtered, repo_opts)
      )
    end)
  end

  @impl true
  def set_tenant(_resource, query, tenant) do
    {:ok, Map.put(Ecto.Query.put_query_prefix(query, to_string(tenant)), :__tenant__, tenant)}
  end

  @impl true
  def run_aggregate_query_with_lateral_join(
        query,
        aggregates,
        root_data,
        destination_resource,
        path
      ) do
    {exists, aggregates} = Enum.split_with(aggregates, &(&1.kind == :exists))

    case lateral_join_query(
           query,
           root_data,
           path
         ) do
      {:ok, lateral_join_query} ->
        source_resource =
          path
          |> Enum.at(0)
          |> elem(0)
          |> Map.get(:resource)

        subquery = from(row in subquery(lateral_join_query), as: ^0, select: %{})
        subquery = default_bindings(subquery, source_resource)

        query =
          Enum.reduce(
            aggregates,
            subquery,
            fn agg, subquery ->
              has_exists? =
                Ash.Filter.find(agg.query && agg.query.filter, fn
                  %Ash.Query.Exists{} -> true
                  _ -> false
                end)

              first_relationship =
                Ash.Resource.Info.relationship(
                  source_resource,
                  agg.relationship_path |> Enum.at(0)
                )

              AshEdgeDB.Aggregate.add_subquery_aggregate_select(
                subquery,
                agg.relationship_path |> Enum.drop(1),
                agg,
                destination_resource,
                has_exists?,
                first_relationship
              )
            end
          )

        result =
          case aggregates do
            [] ->
              %{}

            _ ->
              dynamic_repo(source_resource, query).one(
                query,
                repo_opts(nil, nil, source_resource)
              )
          end

        {:ok, add_exists_aggs(result, source_resource, subquery, exists)}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def run_query_with_lateral_join(
        query,
        root_data,
        _destination_resource,
        path
      ) do
    with_sort_applied =
      if query.__ash_bindings__[:sort_applied?] do
        {:ok, query}
      else
        apply_sort(query, query.__ash_bindings__[:sort], query.__ash_bindings__.resource)
      end

    case with_sort_applied do
      {:error, error} ->
        {:error, error}

      {:ok, query} ->
        case lateral_join_query(
               query,
               root_data,
               path
             ) do
          {:ok, query} ->
            source_resource =
              path
              |> Enum.at(0)
              |> elem(0)
              |> Map.get(:resource)

            {:ok,
             dynamic_repo(source_resource, query).all(
               query,
               repo_opts(nil, nil, source_resource)
             )}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp lateral_join_query(
         query,
         root_data,
         [{source_query, source_attribute, destination_attribute, relationship}]
       ) do
    source_query = Ash.Query.new(source_query)

    base_query =
      if query.__ash_bindings__[:__order__?] do
        from(row in query,
          select_merge: %{__order__: over(row_number(), :order)}
        )
      else
        query
      end

    base_query =
      cond do
        Map.get(relationship, :manual) ->
          {module, opts} = relationship.manual

          module.ash_edgedb_subquery(
            opts,
            0,
            0,
            base_query
          )

        Map.get(relationship, :no_attributes?) ->
          base_query

        true ->
          from(destination in base_query,
            where:
              field(destination, ^destination_attribute) ==
                field(parent_as(^0), ^source_attribute)
          )
      end

    subquery =
      base_query
      |> set_subquery_prefix(source_query, relationship.destination)
      |> subquery()

    source_query.resource
    |> Ash.Query.set_context(%{:data_layer => source_query.context[:data_layer]})
    |> Ash.Query.set_tenant(source_query.tenant)
    |> set_lateral_join_prefix(query)
    |> case do
      %{valid?: true} = query ->
        Ash.Query.data_layer_query(query)

      query ->
        {:error, query}
    end
    |> case do
      {:ok, data_layer_query} ->
        source_values = Enum.map(root_data, &Map.get(&1, source_attribute))

        data_layer_query =
          from(source in data_layer_query,
            where: field(source, ^source_attribute) in ^source_values
          )

        if query.__ash_bindings__[:__order__?] do
          {:ok,
           from(source in data_layer_query,
             inner_lateral_join: destination in ^subquery,
             on: true,
             order_by: destination.__order__,
             select: destination,
             select_merge: %{__lateral_join_source__: field(source, ^source_attribute)},
             distinct: true
           )}
        else
          {:ok,
           from(source in data_layer_query,
             inner_lateral_join: destination in ^subquery,
             on: true,
             select: destination,
             select_merge: %{__lateral_join_source__: field(source, ^source_attribute)},
             distinct: true
           )}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp lateral_join_query(
         query,
         root_data,
         [
           {source_query, source_attribute, source_attribute_on_join_resource, relationship},
           {through_resource, destination_attribute_on_join_resource, destination_attribute,
            through_relationship}
         ]
       ) do
    source_query = Ash.Query.new(source_query)
    source_values = Enum.map(root_data, &Map.get(&1, source_attribute))

    through_resource
    |> Ash.Query.new()
    |> Ash.Query.set_context(through_relationship.context)
    |> Ash.Query.do_filter(through_relationship.filter)
    |> Ash.Query.sort(through_relationship.sort, prepend?: true)
    |> Ash.Query.set_tenant(source_query.tenant)
    |> Ash.Query.put_context(:data_layer, %{
      start_bindings_at: query.__ash_bindings__.current
    })
    |> set_lateral_join_prefix(query)
    |> case do
      %{valid?: true} = through_query ->
        through_query
        |> Ash.Query.data_layer_query()

      query ->
        {:error, query}
    end
    |> case do
      {:ok, through_query} ->
        source_query.resource
        |> Ash.Query.new()
        |> Ash.Query.set_context(relationship.context)
        |> Ash.Query.set_context(%{:data_layer => source_query.context[:data_layer]})
        |> Ash.Query.put_context(:data_layer, %{
          start_bindings_at: through_query.__ash_bindings__.current
        })
        |> set_lateral_join_prefix(query)
        |> Ash.Query.do_filter(relationship.filter)
        |> case do
          %{valid?: true} = query ->
            query
            |> Ash.Query.data_layer_query()

          query ->
            {:error, query}
        end
        |> case do
          {:ok, data_layer_query} ->
            if query.__ash_bindings__[:__order__?] do
              subquery =
                subquery(
                  from(
                    destination in query,
                    select_merge: %{__order__: over(row_number(), :order)},
                    join:
                      through in ^set_subquery_prefix(
                        through_query,
                        source_query,
                        relationship.through
                      ),
                    as: ^query.__ash_bindings__.current,
                    on:
                      field(through, ^destination_attribute_on_join_resource) ==
                        field(destination, ^destination_attribute),
                    where:
                      field(through, ^source_attribute_on_join_resource) ==
                        field(
                          parent_as(^through_query.__ash_bindings__.current),
                          ^source_attribute
                        ),
                    select_merge: %{
                      __lateral_join_source__: field(through, ^source_attribute_on_join_resource)
                    }
                  )
                  |> set_subquery_prefix(
                    source_query,
                    relationship.destination
                  )
                )

              {:ok,
               from(source in data_layer_query,
                 where: field(source, ^source_attribute) in ^source_values,
                 inner_lateral_join: destination in ^subquery,
                 on: true,
                 select: destination,
                 order_by: destination.__order__,
                 distinct: true
               )}
            else
              subquery =
                subquery(
                  from(
                    destination in query,
                    join:
                      through in ^set_subquery_prefix(
                        through_query,
                        source_query,
                        relationship.through
                      ),
                    as: ^query.__ash_bindings__.current,
                    on:
                      field(through, ^destination_attribute_on_join_resource) ==
                        field(destination, ^destination_attribute),
                    where:
                      field(through, ^source_attribute_on_join_resource) ==
                        field(
                          parent_as(^through_query.__ash_bindings__.current),
                          ^source_attribute
                        ),
                    select_merge: %{
                      __lateral_join_source__: field(through, ^source_attribute_on_join_resource)
                    }
                  )
                  |> set_subquery_prefix(
                    source_query,
                    relationship.destination
                  )
                )

              {:ok,
               from(source in data_layer_query,
                 where: field(source, ^source_attribute) in ^source_values,
                 inner_lateral_join: destination in ^subquery,
                 on: true,
                 select: destination,
                 distinct: true
               )}
            end

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  def set_subquery_prefix(data_layer_query, source_query, resource) do
    config = AshEdgeDB.DataLayer.Info.repo(resource, :mutate).config()

    if Ash.Resource.Info.multitenancy_strategy(resource) == :context do
      %{
        data_layer_query
        | prefix:
            to_string(
              source_query.tenant || AshEdgeDB.DataLayer.Info.schema(resource) ||
                config[:default_prefix] ||
                "public"
            )
      }
    else
      %{
        data_layer_query
        | prefix:
            to_string(
              AshEdgeDB.DataLayer.Info.schema(resource) || config[:default_prefix] ||
                "public"
            )
      }
    end
  end

  defp set_lateral_join_prefix(ash_query, query) do
    if Ash.Resource.Info.multitenancy_strategy(ash_query.resource) == :context do
      Ash.Query.set_tenant(ash_query, query.prefix)
    else
      ash_query
    end
  end

  @impl true
  def resource_to_query(resource, _) do
    from(row in {AshEdgeDB.DataLayer.Info.table(resource) || "", resource}, [])
  end

  @impl true
  def bulk_create(resource, stream, options) do
    opts = repo_opts(nil, options[:tenant], resource)

    opts =
      if options.return_records? do
        Keyword.put(opts, :returning, true)
      else
        opts
      end

    changesets = Enum.to_list(stream)

    opts =
      if options[:upsert?] do
        # Ash groups changesets by atomics before dispatching them to the data layer
        # this means that all changesets have the same atomics
        %{atomics: atomics, filters: filters} = Enum.at(changesets, 0)

        query = from(row in resource, as: ^0)

        query =
          query
          |> default_bindings(resource)

        upsert_set =
          upsert_set(resource, changesets, options)

        on_conflict =
          case query_with_atomics(
                 resource,
                 query,
                 filters,
                 atomics,
                 %{},
                 upsert_set
               ) do
            :empty ->
              :nothing

            {:ok, query} ->
              query

            {:error, error} ->
              raise Ash.Error.to_ash_error(error)
          end

        opts
        |> Keyword.put(:on_conflict, on_conflict)
        |> Keyword.put(
          :conflict_target,
          conflict_target(
            resource,
            options[:upsert_keys] || Ash.Resource.Info.primary_key(resource)
          )
        )
      else
        opts
      end

    ecto_changesets = Enum.map(changesets, & &1.attributes)

    source =
      if table = Enum.at(changesets, 0).context[:data_layer][:table] do
        {table, resource}
      else
        resource
      end

    repo = dynamic_repo(resource, Enum.at(changesets, 0))

    source
    |> repo.insert_all(ecto_changesets, opts)
    |> case do
      {_, nil} ->
        :ok

      {_, results} ->
        if options[:single?] do
          Enum.each(results, &maybe_create_tenant!(resource, &1))

          {:ok, results}
        else
          {:ok,
           Stream.zip_with(results, changesets, fn result, changeset ->
             if !opts[:upsert?] do
               maybe_create_tenant!(resource, result)
             end

             Ash.Resource.put_metadata(
               result,
               :bulk_create_index,
               changeset.context.bulk_create.index
             )
           end)}
        end
    end
  rescue
    e ->
      changeset = Ash.Changeset.new(resource)

      handle_raised_error(
        e,
        __STACKTRACE__,
        {:bulk_create, ecto_changeset(changeset.data, changeset, :create, false)},
        resource
      )
  end

  defp upsert_set(resource, changesets, options) do
    attributes_changing_anywhere =
      changesets |> Enum.flat_map(&Map.keys(&1.attributes)) |> Enum.uniq()

    update_defaults = update_defaults(resource)
    # We can't reference EXCLUDED if at least one of the changesets in the stream is not
    # changing the value (and we wouldn't want to even if we could as it would be unnecessary)

    upsert_fields =
      (options[:upsert_fields] || []) |> Enum.filter(&(&1 in attributes_changing_anywhere))

    fields_to_upsert =
      upsert_fields --
        Keyword.keys(Enum.at(changesets, 0).atomics)

    Enum.map(fields_to_upsert, fn upsert_field ->
      # for safety, we check once more at the end that all values in
      # upsert_fields are names of attributes. This is because
      # below we use `literal/1` to bring them into the query
      if is_nil(resource.__schema__(:type, upsert_field)) do
        raise "Only attribute names can be used in upsert_fields"
      end

      case Keyword.fetch(update_defaults, upsert_field) do
        {:ok, default} ->
          if upsert_field in upsert_fields do
            {upsert_field,
             Ecto.Query.dynamic(
               [],
               fragment(
                 "COALESCE(EXCLUDED.?, ?)",
                 literal(^to_string(upsert_field)),
                 ^default
               )
             )}
          else
            {upsert_field, default}
          end

        :error ->
          {upsert_field,
           Ecto.Query.dynamic(
             [],
             fragment("EXCLUDED.?", literal(^to_string(upsert_field)))
           )}
      end
    end)
  end

  @impl true
  def create(resource, changeset) do
    changeset = %{
      changeset
      | data:
          Map.update!(
            changeset.data,
            :__meta__,
            &Map.put(&1, :source, table(resource, changeset))
          )
    }

    case bulk_create(resource, [changeset], %{
           single?: true,
           tenant: changeset.tenant,
           return_records?: true
         }) do
      {:ok, [result]} ->
        {:ok, result}

      {:error, error} ->
        {:error, error}
    end
  end

  defp maybe_create_tenant!(resource, result) do
    if AshEdgeDB.DataLayer.Info.manage_tenant_create?(resource) do
      tenant_name = tenant_name(resource, result)

      AshEdgeDB.MultiTenancy.create_tenant!(
        tenant_name,
        AshEdgeDB.DataLayer.Info.repo(resource, :read)
      )
    else
      :ok
    end
  end

  defp maybe_update_tenant(resource, changeset, result) do
    if AshEdgeDB.DataLayer.Info.manage_tenant_update?(resource) do
      changing_tenant_name? =
        resource
        |> AshEdgeDB.DataLayer.Info.manage_tenant_template()
        |> Enum.filter(&is_atom/1)
        |> Enum.any?(&Ash.Changeset.changing_attribute?(changeset, &1))

      if changing_tenant_name? do
        old_tenant_name = tenant_name(resource, changeset.data)

        new_tenant_name = tenant_name(resource, result)

        AshEdgeDB.MultiTenancy.rename_tenant(
          AshEdgeDB.DataLayer.Info.repo(resource, :read),
          old_tenant_name,
          new_tenant_name
        )
      end
    end

    :ok
  end

  defp tenant_name(resource, result) do
    resource
    |> AshEdgeDB.DataLayer.Info.manage_tenant_template()
    |> Enum.map_join(fn item ->
      if is_binary(item) do
        item
      else
        result
        |> Map.get(item)
        |> to_string()
      end
    end)
  end

  defp handle_errors({:error, %Ecto.Changeset{errors: errors}}) do
    {:error, Enum.map(errors, &to_ash_error/1)}
  end

  defp to_ash_error({field, {message, vars}}) do
    Ash.Error.Changes.InvalidAttribute.exception(
      field: field,
      message: message,
      private_vars: vars
    )
  end

  defp ecto_changeset(record, changeset, type, table_error? \\ true) do
    filters =
      if changeset.action_type == :create do
        %{}
      else
        Map.get(changeset, :filters, %{})
      end

    filters =
      if changeset.action_type == :create do
        filters
      else
        changeset.resource
        |> Ash.Resource.Info.primary_key()
        |> Enum.reduce(filters, fn key, filters ->
          Map.put(filters, key, Map.get(record, key))
        end)
      end

    attributes =
      changeset.resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    attributes_to_change =
      Enum.reject(attributes, fn attribute ->
        Keyword.has_key?(changeset.atomics, attribute)
      end)

    ecto_changeset =
      record
      |> to_ecto()
      |> set_table(changeset, type, table_error?)
      |> Ecto.Changeset.change(Map.take(changeset.attributes, attributes_to_change))
      |> Map.update!(:filters, &Map.merge(&1, filters))
      |> add_configured_foreign_key_constraints(record.__struct__)
      |> add_unique_indexes(record.__struct__, changeset)
      |> add_check_constraints(record.__struct__)
      |> add_exclusion_constraints(record.__struct__)

    case type do
      :create ->
        ecto_changeset
        |> add_my_foreign_key_constraints(record.__struct__)

      type when type in [:upsert, :update] ->
        ecto_changeset
        |> add_my_foreign_key_constraints(record.__struct__)
        |> add_related_foreign_key_constraints(record.__struct__)

      :delete ->
        ecto_changeset
        |> add_related_foreign_key_constraints(record.__struct__)
    end
  end

  defp handle_raised_error(
         %Ecto.StaleEntryError{changeset: %{data: %resource{}, filters: filters}},
         stacktrace,
         context,
         resource
       ) do
    handle_raised_error(
      Ash.Error.Changes.StaleRecord.exception(resource: resource, filters: filters),
      stacktrace,
      context,
      resource
    )
  end

  defp handle_raised_error(
         %Postgrex.Error{
           postgres: %{
             code: :lock_not_available,
             message: message
           }
         },
         stacktrace,
         context,
         resource
       ) do
    handle_raised_error(
      Ash.Error.Invalid.Unavailable.exception(
        resource: resource,
        source: inspect(context, pretty: true),
        reason: message
      ),
      stacktrace,
      context,
      resource
    )
  end

  defp handle_raised_error(
         %Postgrex.Error{} = error,
         stacktrace,
         {:bulk_create, fake_changeset},
         _resource
       ) do
    case Ecto.Adapters.Postgres.Connection.to_constraints(error, []) do
      [] ->
        {:error, Ash.Error.to_ash_error(error, stacktrace)}

      constraints ->
        {:error,
         fake_changeset
         |> constraints_to_errors(:insert, constraints)
         |> Ash.Error.to_ash_error()}
    end
  end

  defp handle_raised_error(%Ecto.Query.CastError{} = e, stacktrace, context, resource) do
    handle_raised_error(
      Ash.Error.Query.InvalidFilterValue.exception(value: e.value, context: context),
      stacktrace,
      context,
      resource
    )
  end

  defp handle_raised_error(
         %Postgrex.Error{} = error,
         stacktrace,
         %{constraints: user_constraints},
         _resource
       ) do
    case Ecto.Adapters.Postgres.Connection.to_constraints(error, []) do
      [{type, constraint}] ->
        user_constraint =
          Enum.find(user_constraints, fn c ->
            case {c.type, c.constraint, c.match} do
              {^type, ^constraint, :exact} -> true
              {^type, cc, :suffix} -> String.ends_with?(constraint, cc)
              {^type, cc, :prefix} -> String.starts_with?(constraint, cc)
              {^type, %Regex{} = r, _match} -> Regex.match?(r, constraint)
              _ -> false
            end
          end)

        case user_constraint do
          %{field: field, error_message: error_message, error_type: error_type} ->
            {:error,
             to_ash_error(
               {field, {error_message, [constraint: error_type, constraint_name: constraint]}}
             )}

          nil ->
            reraise error, stacktrace
        end

      _ ->
        reraise error, stacktrace
    end
  end

  defp handle_raised_error(error, stacktrace, _ecto_changeset, _resource) do
    {:error, Ash.Error.to_ash_error(error, stacktrace)}
  end

  defp constraints_to_errors(%{constraints: user_constraints} = changeset, action, constraints) do
    Enum.map(constraints, fn {type, constraint} ->
      user_constraint =
        Enum.find(user_constraints, fn c ->
          case {c.type, c.constraint, c.match} do
            {^type, ^constraint, :exact} -> true
            {^type, cc, :suffix} -> String.ends_with?(constraint, cc)
            {^type, cc, :prefix} -> String.starts_with?(constraint, cc)
            {^type, %Regex{} = r, _match} -> Regex.match?(r, constraint)
            _ -> false
          end
        end)

      case user_constraint do
        %{field: field, error_message: error_message, type: type, constraint: constraint} ->
          Ash.Error.Changes.InvalidAttribute.exception(
            field: field,
            message: error_message,
            private_vars: [
              constraint: constraint,
              constraint_type: type
            ]
          )

        nil ->
          Ecto.ConstraintError.exception(
            action: action,
            type: type,
            constraint: constraint,
            changeset: changeset
          )
      end
    end)
  end

  defp set_table(record, changeset, operation, table_error?) do
    if AshEdgeDB.DataLayer.Info.polymorphic?(record.__struct__) do
      table =
        changeset.context[:data_layer][:table] ||
          AshEdgeDB.DataLayer.Info.table(record.__struct__)

      record =
        if table do
          Ecto.put_meta(record, source: table)
        else
          if table_error? do
            raise_table_error!(changeset.resource, operation)
          else
            record
          end
        end

      prefix =
        changeset.context[:data_layer][:schema] ||
          AshEdgeDB.DataLayer.Info.schema(record.__struct__)

      if prefix do
        Ecto.put_meta(record, prefix: table)
      else
        record
      end
    else
      record
    end
  end

  def from_ecto({:ok, result}), do: {:ok, from_ecto(result)}
  def from_ecto({:error, _} = other), do: other

  def from_ecto(nil), do: nil

  def from_ecto(value) when is_list(value) do
    Enum.map(value, &from_ecto/1)
  end

  def from_ecto(%resource{} = record) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      empty = struct(resource)

      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce(record, fn relationship, record ->
        case Map.get(record, relationship.name) do
          %Ecto.Association.NotLoaded{} ->
            Map.put(record, relationship.name, Map.get(empty, relationship.name))

          value ->
            Map.put(record, relationship.name, from_ecto(value))
        end
      end)
    else
      record
    end
  end

  def from_ecto(other), do: other

  def to_ecto(nil), do: nil

  def to_ecto(value) when is_list(value) do
    Enum.map(value, &to_ecto/1)
  end

  def to_ecto(%resource{} = record) do
    if Spark.Dsl.is?(resource, Ash.Resource) do
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce(record, fn relationship, record ->
        value =
          case Map.get(record, relationship.name) do
            %Ash.NotLoaded{} ->
              %Ecto.Association.NotLoaded{
                __field__: relationship.name,
                __cardinality__: relationship.cardinality
              }

            value ->
              to_ecto(value)
          end

        Map.put(record, relationship.name, value)
      end)
    else
      record
    end
  end

  def to_ecto(other), do: other

  defp add_check_constraints(changeset, resource) do
    resource
    |> AshEdgeDB.DataLayer.Info.check_constraints()
    |> Enum.reduce(changeset, fn constraint, changeset ->
      constraint.attribute
      |> List.wrap()
      |> Enum.reduce(changeset, fn attribute, changeset ->
        Ecto.Changeset.check_constraint(changeset, attribute,
          name: constraint.name,
          message: constraint.message || "is invalid"
        )
      end)
    end)
  end

  defp add_exclusion_constraints(changeset, resource) do
    resource
    |> AshEdgeDB.DataLayer.Info.exclusion_constraint_names()
    |> Enum.reduce(changeset, fn constraint, changeset ->
      case constraint do
        {key, name} ->
          Ecto.Changeset.exclusion_constraint(changeset, key, name: name)

        {key, name, message} ->
          Ecto.Changeset.exclusion_constraint(changeset, key, name: name, message: message)
      end
    end)
  end

  defp add_related_foreign_key_constraints(changeset, resource) do
    # TODO: this doesn't guarantee us to get all of them, because if something is related to this
    # schema and there is no back-relation, then this won't catch it's foreign key constraints
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.map(& &1.destination)
    |> Enum.uniq()
    |> Enum.flat_map(fn related ->
      related
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&(&1.destination == resource))
      |> Enum.map(&Map.take(&1, [:source, :source_attribute, :destination_attribute, :name]))
    end)
    |> Enum.reduce(changeset, fn %{
                                   source: source,
                                   source_attribute: source_attribute,
                                   destination_attribute: destination_attribute,
                                   name: relationship_name
                                 },
                                 changeset ->
      case AshEdgeDB.DataLayer.Info.reference(resource, relationship_name) do
        %{name: name} when not is_nil(name) ->
          Ecto.Changeset.foreign_key_constraint(changeset, destination_attribute,
            name: name,
            message: "would leave records behind"
          )

        _ ->
          Ecto.Changeset.foreign_key_constraint(changeset, destination_attribute,
            name: "#{AshEdgeDB.DataLayer.Info.table(source)}_#{source_attribute}_fkey",
            message: "would leave records behind"
          )
      end
    end)
  end

  defp add_my_foreign_key_constraints(changeset, resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.reduce(changeset, &Ecto.Changeset.foreign_key_constraint(&2, &1.source_attribute))
  end

  defp add_configured_foreign_key_constraints(changeset, resource) do
    resource
    |> AshEdgeDB.DataLayer.Info.foreign_key_names()
    |> case do
      {m, f, a} -> List.wrap(apply(m, f, [changeset | a]))
      value -> List.wrap(value)
    end
    |> Enum.reduce(changeset, fn
      {key, name}, changeset ->
        Ecto.Changeset.foreign_key_constraint(changeset, key, name: name)

      {key, name, message}, changeset ->
        Ecto.Changeset.foreign_key_constraint(changeset, key, name: name, message: message)
    end)
  end

  defp add_unique_indexes(changeset, resource, ash_changeset) do
    changeset =
      resource
      |> Ash.Resource.Info.identities()
      |> Enum.reduce(changeset, fn identity, changeset ->
        name =
          AshEdgeDB.DataLayer.Info.identity_index_names(resource)[identity.name] ||
            "#{table(resource, ash_changeset)}_#{identity.name}_index"

        opts =
          if Map.get(identity, :message) do
            [name: name, message: identity.message]
          else
            [name: name]
          end

        Ecto.Changeset.unique_constraint(changeset, identity.keys, opts)
      end)

    changeset =
      resource
      |> AshEdgeDB.DataLayer.Info.custom_indexes()
      |> Enum.reduce(changeset, fn index, changeset ->
        opts =
          if index.message do
            [name: index.name, message: index.message]
          else
            [name: index.name]
          end

        Ecto.Changeset.unique_constraint(changeset, index.fields, opts)
      end)

    names =
      resource
      |> AshEdgeDB.DataLayer.Info.unique_index_names()
      |> case do
        {m, f, a} -> List.wrap(apply(m, f, [changeset | a]))
        value -> List.wrap(value)
      end

    names =
      case Ash.Resource.Info.primary_key(resource) do
        [] ->
          names

        fields ->
          if table = table(resource, ash_changeset) do
            [{fields, table <> "_pkey"} | names]
          else
            []
          end
      end

    Enum.reduce(names, changeset, fn
      {keys, name}, changeset ->
        Ecto.Changeset.unique_constraint(changeset, List.wrap(keys), name: name)

      {keys, name, message}, changeset ->
        Ecto.Changeset.unique_constraint(changeset, List.wrap(keys), name: name, message: message)
    end)
  end

  @impl true
  def upsert(resource, changeset, keys \\ nil) do
    if AshEdgeDB.DataLayer.Info.manage_tenant_update?(resource) do
      {:error, "Cannot currently upsert a resource that owns a tenant"}
    else
      keys = keys || Ash.Resource.Info.primary_key(keys)

      update_defaults = update_defaults(resource)

      explicitly_changing_attributes =
        changeset.attributes
        |> Map.keys()
        |> Enum.concat(Keyword.keys(update_defaults))
        |> Kernel.--(Map.get(changeset, :defaults, []))
        |> Kernel.--(keys)

      upsert_fields =
        changeset.context[:private][:upsert_fields] || explicitly_changing_attributes

      case bulk_create(resource, [changeset], %{
             single?: true,
             upsert?: true,
             tenant: changeset.tenant,
             upsert_keys: keys,
             upsert_fields: upsert_fields,
             return_records?: true
           }) do
        {:ok, [result]} ->
          {:ok, result}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp conflict_target(resource, keys) do
    if Ash.Resource.Info.base_filter(resource) do
      base_filter_sql =
        AshEdgeDB.DataLayer.Info.base_filter_sql(resource) ||
          raise """
          Cannot use upserts with resources that have a base_filter without also adding `base_filter_sql` in the postgres section.
          """

      sources =
        Enum.map(keys, fn key ->
          ~s("#{Ash.Resource.Info.attribute(resource, key).source || key}")
        end)

      {:unsafe_fragment, "(" <> Enum.join(sources, ", ") <> ") WHERE (#{base_filter_sql})"}
    else
      keys
    end
  end

  defp update_defaults(resource) do
    attributes =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.reject(&is_nil(&1.update_default))

    attributes
    |> static_defaults()
    |> Enum.concat(lazy_matching_defaults(attributes))
    |> Enum.concat(lazy_non_matching_defaults(attributes))
  end

  defp static_defaults(attributes) do
    attributes
    |> Enum.reject(&get_default_fun(&1))
    |> Enum.map(&{&1.name, &1.update_default})
  end

  defp lazy_non_matching_defaults(attributes) do
    attributes
    |> Enum.filter(&(!&1.match_other_defaults? && get_default_fun(&1)))
    |> Enum.map(fn attribute ->
      default_value =
        case attribute.update_default do
          function when is_function(function) ->
            function.()

          {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
            apply(m, f, a)
        end

      {attribute.name, default_value}
    end)
  end

  defp lazy_matching_defaults(attributes) do
    attributes
    |> Enum.filter(&(&1.match_other_defaults? && get_default_fun(&1)))
    |> Enum.group_by(& &1.update_default)
    |> Enum.flat_map(fn {default_fun, attributes} ->
      default_value =
        case default_fun do
          function when is_function(function) ->
            function.()

          {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
            apply(m, f, a)
        end

      Enum.map(attributes, &{&1.name, default_value})
    end)
  end

  defp get_default_fun(attribute) do
    if is_function(attribute.update_default) or match?({_, _, _}, attribute.update_default) do
      attribute.update_default
    end
  end

  @impl true
  def update(resource, changeset) do
    ecto_changeset =
      changeset.data
      |> Map.update!(:__meta__, &Map.put(&1, :source, table(resource, changeset)))
      |> ecto_changeset(changeset, :update)

    try do
      query = from(row in resource, as: ^0)

      select = Keyword.keys(changeset.atomics) ++ Ash.Resource.Info.primary_key(resource)

      query =
        query
        |> default_bindings(resource, changeset.context)
        |> Ecto.Query.select(^select)

      case query_with_atomics(
             resource,
             query,
             ecto_changeset.filters,
             changeset.atomics,
             ecto_changeset.changes,
             []
           ) do
        :empty ->
          {:ok, changeset.data}

        {:ok, query} ->
          repo_opts = repo_opts(changeset.timeout, changeset.tenant, changeset.resource)

          repo_opts =
            Keyword.put(repo_opts, :returning, Keyword.keys(changeset.atomics))

          result =
            dynamic_repo(resource, changeset).update_all(
              query,
              [],
              repo_opts
            )

          case result do
            {0, []} ->
              {:error,
               Ash.Error.Changes.StaleRecord.exception(
                 resource: resource,
                 filters: ecto_changeset.filters
               )}

            {1, [result]} ->
              record =
                changeset.data
                |> Map.merge(changeset.attributes)
                |> Map.merge(Map.take(result, Keyword.keys(changeset.atomics)))

              maybe_update_tenant(resource, changeset, record)

              {:ok, record}
          end

        {:error, error} ->
          {:error, error}
      end
    rescue
      e ->
        handle_raised_error(e, __STACKTRACE__, ecto_changeset, resource)
    end
  end

  defp query_with_atomics(
         resource,
         query,
         filters,
         atomics,
         updating_one_changes,
         existing_set
       ) do
    query =
      Enum.reduce(filters, query, fn {key, value}, query ->
        from(row in query,
          where: field(row, ^key) == ^value
        )
      end)

    atomics_result =
      Enum.reduce_while(atomics, {:ok, query, []}, fn {field, expr}, {:ok, query, set} ->
        used_calculations =
          Ash.Filter.used_calculations(
            expr,
            resource
          )

        used_aggregates =
          expr
          |> AshEdgeDB.Aggregate.used_aggregates(
            resource,
            used_calculations,
            []
          )
          |> Enum.map(fn aggregate ->
            %{aggregate | load: aggregate.name}
          end)

        with {:ok, query} <-
               AshEdgeDB.Join.join_all_relationships(
                 query,
                 %Ash.Filter{
                   resource: resource,
                   expression: expr
                 },
                 left_only?: true
               ),
             {:ok, query} <-
               AshEdgeDB.Aggregate.add_aggregates(query, used_aggregates, resource, false, 0),
             dynamic <-
               AshEdgeDB.Expr.dynamic_expr(query, expr, query.__ash_bindings__) do
          {:cont, {:ok, query, Keyword.put(set, field, dynamic)}}
        else
          other ->
            {:halt, other}
        end
      end)

    case atomics_result do
      {:ok, query, dynamics} ->
        {params, set, count} =
          updating_one_changes
          |> Map.to_list()
          |> Enum.reduce({[], [], 0}, fn {key, value}, {params, set, count} ->
            {[{value, {0, key}} | params], [{key, {:^, [], [count]}} | set], count + 1}
          end)

        {params, set, _} =
          Enum.reduce(
            dynamics ++ existing_set,
            {params, set, count},
            fn {key, value}, {params, set, count} ->
              case AshEdgeDB.Expr.dynamic_expr(query, value, query.__ash_bindings__) do
                %Ecto.Query.DynamicExpr{} = dynamic ->
                  result =
                    Ecto.Query.Builder.Dynamic.partially_expand(
                      :select,
                      query,
                      dynamic,
                      params,
                      count
                    )

                  expr = elem(result, 0)
                  new_params = elem(result, 1)

                  new_count =
                    result |> Tuple.to_list() |> List.last()

                  {new_params, [{key, expr} | set], new_count}

                other ->
                  {[{other, {0, key}} | params], [{key, {:^, [], [count]}} | set], count + 1}
              end
            end
          )

        case set do
          [] ->
            :empty

          set ->
            {:ok,
             Map.put(query, :updates, [
               %Ecto.Query.QueryExpr{
                 # why do I have to reverse the `set`???
                 # it breaks if I don't
                 expr: [set: Enum.reverse(set)],
                 params: Enum.reverse(params)
               }
             ])}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def destroy(resource, %{data: record} = changeset) do
    ecto_changeset = ecto_changeset(record, changeset, :delete)

    try do
      ecto_changeset
      |> dynamic_repo(resource, changeset).delete(
        repo_opts(changeset.timeout, changeset.tenant, changeset.resource)
      )
      |> from_ecto()
      |> case do
        {:ok, _record} ->
          :ok

        {:error, error} ->
          handle_errors({:error, error})
      end
    rescue
      e ->
        handle_raised_error(e, __STACKTRACE__, ecto_changeset, resource)
    end
  end

  @impl true
  def lock(query, :for_update, _) do
    if query.distinct do
      new_query =
        Ecto.Query.lock(%{query | distinct: nil}, [{^0, a}], fragment("FOR UPDATE OF ?", a))

      q = from(row in subquery(new_query), [])
      {:ok, %{q | distinct: query.distinct}}
    else
      {:ok, Ecto.Query.lock(query, [{^0, a}], fragment("FOR UPDATE OF ?", a))}
    end
  end

  @locks [
    "FOR UPDATE",
    "FOR NO KEY UPDATE",
    "FOR SHARE",
    "FOR KEY SHARE"
  ]

  for lock <- @locks do
    frag = "#{lock} OF ?"

    def lock(query, unquote(lock), _) do
      {:ok, Ecto.Query.lock(query, [{^0, a}], fragment(unquote(frag), a))}
    end

    frag = "#{lock} OF ? NOWAIT"
    lock = "#{lock} NOWAIT"

    def lock(query, unquote(lock), _) do
      {:ok, Ecto.Query.lock(query, [{^0, a}], fragment(unquote(frag), a))}
    end
  end

  @impl true
  def sort(query, sort, _resource) do
    {:ok, Map.update!(query, :__ash_bindings__, &Map.put(&1, :sort, sort))}
  end

  @impl true
  def select(query, select, resource) do
    query = default_bindings(query, resource)

    {:ok,
     from(row in query,
       select: struct(row, ^Enum.uniq(select))
     )}
  end

  @impl true
  def distinct_sort(query, sort, _) when sort in [nil, []] do
    {:ok, query}
  end

  def distinct_sort(query, sort, _) do
    {:ok, Map.update!(query, :__ash_bindings__, &Map.put(&1, :distinct_sort, sort))}
  end

  # If the order by does not match the initial sort clause, then we use a subquery
  # to limit to only distinct rows. This may not perform that well, so we may need
  # to come up with alternatives here.
  @impl true
  def distinct(query, empty, resource) when empty in [nil, []] do
    query |> apply_sort(query.__ash_bindings__[:sort], resource)
  end

  def distinct(query, distinct_on, resource) do
    case get_distinct_statement(query, distinct_on) do
      {:ok, distinct_statement} ->
        %{query | distinct: distinct_statement}
        |> apply_sort(query.__ash_bindings__[:sort], resource)

      {:error, distinct_statement} ->
        query
        |> Ecto.Query.exclude(:order_by)
        |> default_bindings(resource)
        |> Map.put(:distinct, distinct_statement)
        |> apply_sort(
          query.__ash_bindings__[:distinct_sort] || query.__ash_bindings__[:sort],
          resource,
          :direct
        )
        |> case do
          {:ok, distinct_query} ->
            on =
              Enum.reduce(Ash.Resource.Info.primary_key(resource), nil, fn key, dynamic ->
                if dynamic do
                  Ecto.Query.dynamic(
                    [row, distinct],
                    ^dynamic and field(row, ^key) == field(distinct, ^key)
                  )
                else
                  Ecto.Query.dynamic([row, distinct], field(row, ^key) == field(distinct, ^key))
                end
              end)

            joined_query_source =
              Enum.reduce(
                [
                  :join,
                  :order_by,
                  :group_by,
                  :having,
                  :distinct,
                  :select,
                  :combinations,
                  :with_ctes,
                  :limit,
                  :offset,
                  :lock,
                  :preload,
                  :update,
                  :where
                ],
                query,
                &Ecto.Query.exclude(&2, &1)
              )

            joined_query =
              from(row in joined_query_source,
                join: distinct in subquery(distinct_query),
                on: ^on
              )

            from([row, distinct] in joined_query,
              select: distinct
            )
            |> default_bindings(resource)
            |> apply_sort(query.__ash_bindings__[:sort], resource)
            |> case do
              {:ok, joined_query} ->
                {:ok,
                 Map.update!(
                   joined_query,
                   :__ash_bindings__,
                   &Map.put(&1, :__order__?, query.__ash_bindings__[:__order__?] || false)
                 )}

              {:error, error} ->
                {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp apply_sort(query, sort, resource, type \\ :window)

  defp apply_sort(query, sort, _resource, _) when sort in [nil, []] do
    {:ok, query |> set_sort_applied()}
  end

  defp apply_sort(query, sort, resource, type) do
    AshEdgeDB.Sort.sort(query, sort, resource, [], 0, type)
  end

  defp set_sort_applied(query) do
    Map.update!(query, :__ash_bindings__, &Map.put(&1, :sort_applied?, true))
  end

  defp get_distinct_statement(query, distinct_on) do
    has_distinct_sort? = match?(%{__ash_bindings__: %{distinct_sort: _}}, query)

    if has_distinct_sort? do
      {:error, default_distinct_statement(query, distinct_on)}
    else
      sort = query.__ash_bindings__[:sort] || []

      distinct =
        query.distinct ||
          %Ecto.Query.QueryExpr{
            expr: [],
            params: []
          }

      if sort == [] do
        {:ok, default_distinct_statement(query, distinct_on)}
      else
        distinct_on
        |> Enum.reduce_while({sort, [], [], Enum.count(distinct.params)}, fn
          _, {[], _distinct_statement, _, _count} ->
            {:halt, :error}

          distinct_on, {[order_by | rest_order_by], distinct_statement, params, count} ->
            case order_by do
              {^distinct_on, order} ->
                {distinct_expr, params, count} =
                  distinct_on_expr(query, distinct_on, params, count)

                {:cont,
                 {rest_order_by, [{order, distinct_expr} | distinct_statement], params, count}}

              _ ->
                {:halt, :error}
            end
        end)
        |> case do
          :error ->
            {:error, default_distinct_statement(query, distinct_on)}

          {_, result, params, _} ->
            {:ok,
             %{
               distinct
               | expr: distinct.expr ++ Enum.reverse(result),
                 params: distinct.params ++ Enum.reverse(params)
             }}
        end
      end
    end
  end

  defp default_distinct_statement(query, distinct_on) do
    distinct =
      query.distinct ||
        %Ecto.Query.QueryExpr{
          expr: []
        }

    {expr, params, _} =
      Enum.reduce(distinct_on, {[], [], Enum.count(distinct.params)}, fn
        {distinct_on_field, order}, {expr, params, count} ->
          {distinct_expr, params, count} =
            distinct_on_expr(query, distinct_on_field, params, count)

          {[{order, distinct_expr} | expr], params, count}

        distinct_on_field, {expr, params, count} ->
          {distinct_expr, params, count} =
            distinct_on_expr(query, distinct_on_field, params, count)

          {[{:asc, distinct_expr} | expr], params, count}
      end)

    %{
      distinct
      | expr: distinct.expr ++ Enum.reverse(expr),
        params: distinct.params ++ Enum.reverse(params)
    }
  end

  defp distinct_on_expr(query, field, params, count) do
    resource = query.__ash_bindings__.resource

    ref =
      case field do
        %Ash.Query.Calculation{} = calc ->
          %Ref{attribute: calc, relationship_path: [], resource: resource}

        field ->
          %Ref{
            attribute: Ash.Resource.Info.field(resource, field),
            relationship_path: [],
            resource: resource
          }
      end

    dynamic = AshEdgeDB.Expr.dynamic_expr(query, ref, query.__ash_bindings__)

    result =
      Ecto.Query.Builder.Dynamic.partially_expand(
        :distinct,
        query,
        dynamic,
        params,
        count
      )

    expr = elem(result, 0)
    new_params = elem(result, 1)
    new_count = result |> Tuple.to_list() |> List.last()

    {expr, new_params, new_count}
  end

  @impl true
  def filter(query, filter, resource, opts \\ []) do
    query = default_bindings(query, resource)

    used_calculations =
      Ash.Filter.used_calculations(
        filter,
        resource
      )

    used_aggregates =
      filter
      |> AshEdgeDB.Aggregate.used_aggregates(
        resource,
        used_calculations,
        []
      )
      |> Enum.map(fn aggregate ->
        %{aggregate | load: aggregate.name}
      end)

    query
    |> AshEdgeDB.Join.join_all_relationships(filter, opts)
    |> case do
      {:ok, query} ->
        query
        |> AshEdgeDB.Aggregate.add_aggregates(used_aggregates, resource, false, 0)
        |> case do
          {:ok, query} ->
            {:ok, add_filter_expression(query, filter)}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  def default_bindings(query, resource, context \\ %{})
  def default_bindings(%{__ash_bindings__: _} = query, _resource, _context), do: query

  def default_bindings(query, resource, context) do
    start_bindings = context[:data_layer][:start_bindings_at] || 0

    Map.put_new(query, :__ash_bindings__, %{
      resource: resource,
      current: Enum.count(query.joins) + 1 + start_bindings,
      in_group?: false,
      calculations: %{},
      parent_resources: [],
      aggregate_defs: %{},
      current_aggregate_name: :aggregate_0,
      aggregate_names: %{},
      context: context,
      bindings: %{start_bindings => %{path: [], type: :root, source: resource}}
    })
  end

  @impl true
  def add_aggregates(query, aggregates, resource) do
    AshEdgeDB.Aggregate.add_aggregates(query, aggregates, resource, true, 0)
  end

  @impl true
  def add_calculations(query, calculations, resource) do
    AshEdgeDB.Calculation.add_calculations(query, calculations, resource, 0)
  end

  @doc false
  def get_binding(resource, path, query, type, name_match \\ nil)

  def get_binding(resource, path, %{__ash_bindings__: _} = query, type, name_match) do
    types = List.wrap(type)

    Enum.find_value(query.__ash_bindings__.bindings, fn
      {binding, %{path: candidate_path, type: binding_type} = data} ->
        if binding_type in types do
          if name_match do
            if data[:name] == name_match do
              if Ash.SatSolver.synonymous_relationship_paths?(resource, candidate_path, path) do
                binding
              end
            end
          else
            if Ash.SatSolver.synonymous_relationship_paths?(resource, candidate_path, path) do
              binding
            else
              false
            end
          end
        end

      _ ->
        nil
    end)
  end

  def get_binding(_, _, _, _, _), do: nil

  defp add_filter_expression(query, filter) do
    filter
    |> split_and_statements()
    |> Enum.reduce(query, fn filter, query ->
      dynamic = AshEdgeDB.Expr.dynamic_expr(query, filter, query.__ash_bindings__)

      Ecto.Query.where(query, ^dynamic)
    end)
  end

  defp split_and_statements(%Filter{expression: expression}) do
    split_and_statements(expression)
  end

  defp split_and_statements(%BooleanExpression{op: :and, left: left, right: right}) do
    split_and_statements(left) ++ split_and_statements(right)
  end

  defp split_and_statements(%Not{expression: %Not{expression: expression}}) do
    split_and_statements(expression)
  end

  defp split_and_statements(%Not{
         expression: %BooleanExpression{op: :or, left: left, right: right}
       }) do
    split_and_statements(%BooleanExpression{
      op: :and,
      left: %Not{expression: left},
      right: %Not{expression: right}
    })
  end

  defp split_and_statements(other), do: [other]

  @doc false
  def add_binding(query, data, additional_bindings \\ 0) do
    current = query.__ash_bindings__.current
    bindings = query.__ash_bindings__.bindings

    new_ash_bindings = %{
      query.__ash_bindings__
      | bindings: Map.put(bindings, current, data),
        current: current + 1 + additional_bindings
    }

    %{query | __ash_bindings__: new_ash_bindings}
  end

  def add_known_binding(query, data, known_binding) do
    bindings = query.__ash_bindings__.bindings

    new_ash_bindings = %{
      query.__ash_bindings__
      | bindings: Map.put(bindings, known_binding, data)
    }

    %{query | __ash_bindings__: new_ash_bindings}
  end

  @impl true
  def transaction(resource, func, timeout \\ nil, reason \\ %{type: :custom, metadata: %{}}) do
    repo =
      case reason[:data_layer_context] do
        %{repo: repo} when not is_nil(repo) ->
          repo

        _ ->
          AshEdgeDB.DataLayer.Info.repo(resource, :read)
      end

    func = fn ->
      repo.on_transaction_begin(reason)
      func.()
    end

    if timeout do
      repo.transaction(func, timeout: timeout)
    else
      repo.transaction(func)
    end
  end

  @impl true
  def rollback(resource, term) do
    AshEdgeDB.DataLayer.Info.repo(resource, :mutate).rollback(term)
  end

  defp table(resource, changeset) do
    changeset.context[:data_layer][:table] || AshEdgeDB.DataLayer.Info.table(resource)
  end

  defp raise_table_error!(resource, operation) do
    if AshEdgeDB.DataLayer.Info.polymorphic?(resource) do
      raise """
      Could not determine table for #{operation} on #{inspect(resource)}.

      Polymorphic resources require that the `data_layer[:table]` context is provided.
      See the guide on polymorphic resources for more information.
      """
    else
      raise """
      Could not determine table for #{operation} on #{inspect(resource)}.
      """
    end
  end

  defp dynamic_repo(resource, %{__ash_bindings__: %{context: %{data_layer: %{repo: repo}}}}) do
    repo || AshEdgeDB.DataLayer.Info.repo(resource, :read)
  end

  defp dynamic_repo(resource, %struct{context: %{data_layer: %{repo: repo}}}) do
    type = struct_to_repo_type(struct)

    repo || AshEdgeDB.DataLayer.Info.repo(resource, type)
  end

  defp dynamic_repo(resource, %struct{}) do
    AshEdgeDB.DataLayer.Info.repo(resource, struct_to_repo_type(struct))
  end

  defp struct_to_repo_type(struct) do
    case struct do
      Ash.Changeset -> :mutate
      Ash.Query -> :read
      Ecto.Query -> :read
      Ecto.Changeset -> :mutate
    end
  end
end
