defmodule Ecto.Migrator do
  @moduledoc """
  This module provides the migration API.

  ## Example

      defmodule MyApp.MigrationExample do
        use Ecto.Migration

        def up do
          execute "CREATE TABLE users(id serial PRIMARY_KEY, username text)"
        end

        def down do
          execute "DROP TABLE users"
        end
      end

      Ecto.Migrator.up(Repo, 20080906120000, MyApp.MigrationExample)

  """

  require Logger

  alias Ecto.Migration.Runner
  alias Ecto.Migration.SchemaMigration

  @doc """
  Gets the migrations path from a repository.
  """
  @spec migrations_path(Ecto.Repo.t) :: String.t
  def migrations_path(repo) do
    config = repo.config()
    priv = config[:priv] || "priv/#{repo |> Module.split |> List.last |> Macro.underscore}"
    app = Keyword.fetch!(config, :otp_app)
    Application.app_dir(app, Path.join(priv, "migrations"))
  end

  @doc """
  Gets all migrated versions.

  This function ensures the migration table exists
  if no table has been defined yet.

  ## Options

    * `:prefix` - the prefix to run the migrations on

  """
  @spec migrated_versions(Ecto.Repo.t, Keyword.t) :: [integer]
  def migrated_versions(repo, opts \\ []) do
    verbose_schema_migration repo, "retrieve migrated versions", fn ->
      SchemaMigration.ensure_schema_migrations_table!(repo, opts[:prefix])
    end

    lock_for_migrations repo, opts, fn versions -> versions end
  end

  @doc """
  Runs an up migration on the given repository.

  ## Options

    * `:log` - the level to use for logging of migration instructions.
      Defaults to `:info`. Can be any of `Logger.level/0` values or a boolean.
    * `:log_sql` - the level to use for logging of SQL instructions.
      Defaults to `false`. Can be any of `Logger.level/0` values or a boolean.
    * `:prefix` - the prefix to run the migrations on
    * `:strict_version_order` - abort when applying a migration with old timestamp
  """
  @spec up(Ecto.Repo.t, integer, module, Keyword.t) :: :ok | :already_up
  def up(repo, version, module, opts \\ []) do
    verbose_schema_migration repo, "create schema migrations table", fn ->
      SchemaMigration.ensure_schema_migrations_table!(repo, opts[:prefix])
    end

    lock_for_migrations repo, opts, fn versions ->
      if version in versions do
        :already_up
      else
        result = do_up(repo, version, module, opts)

        if version != Enum.max([version | versions]) do
          latest = Enum.max(versions)

          message = """
          You are running migration #{version} but an older \
          migration with version #{latest} has already run.

          This can be an issue if you have already ran #{latest} in production \
          because a new deployment may migrate #{version} but a rollback command \
          would revert #{latest} instead of #{version}.

          If this can be an issue, we recommend to rollback #{version} and change \
          it to a version later than #{latest}.
          """

          if opts[:strict_version_order] do
            raise Ecto.MigrationError, message
          else
            Logger.warn message
          end
        end

        result
      end
    end
  end

  defp do_up(repo, version, module, opts) do
    async_migrate_maybe_in_transaction(repo, version, module, :up, opts, fn ->
      attempt(repo, version, module, :forward, :up, :up, opts)
        || attempt(repo, version, module, :forward, :change, :up, opts)
        || {:error, Ecto.MigrationError.exception(
            "#{inspect module} does not implement a `up/0` or `change/0` function")}
    end)
  end

  @doc """
  Runs a down migration on the given repository.

  ## Options

    * `:log` - the level to use for logging. Defaults to `:info`.
      Can be any of `Logger.level/0` values or a boolean.
    * `:log_sql` - the level to use for logging of SQL instructions.
      Defaults to `false`. Can be any of `Logger.level/0` values or a boolean.
    * `:prefix` - the prefix to run the migrations on

  """
  @spec down(Ecto.Repo.t, integer, module) :: :ok | :already_down
  def down(repo, version, module, opts \\ []) do
    verbose_schema_migration repo, "create schema migrations table", fn ->
      SchemaMigration.ensure_schema_migrations_table!(repo, opts[:prefix])
    end

    lock_for_migrations repo, opts, fn versions ->
      if version in versions do
        do_down(repo, version, module, opts)
      else
        :already_down
      end
    end
  end

  defp do_down(repo, version, module, opts) do
    async_migrate_maybe_in_transaction(repo, version, module, :down, opts, fn ->
      attempt(repo, version, module, :forward, :down, :down, opts)
        || attempt(repo, version, module, :backward, :change, :down, opts)
        || {:error, Ecto.MigrationError.exception(
            "#{inspect module} does not implement a `down/0` or `change/0` function")}
    end)
  end

  defp async_migrate_maybe_in_transaction(repo, version, module, direction, opts, fun) do
    parent = self()
    ref = make_ref()
    task = Task.async(fn -> run_maybe_in_transaction(parent, ref, repo, module, fun) end)

    if migrated_successfully?(ref, task.pid) do
      try do
        # The table with schema migrations can only be updated from
        # the parent process because it has a lock on the table
        verbose_schema_migration repo, "update schema migrations", fn ->
          apply(SchemaMigration, direction, [repo, version, opts[:prefix]])
        end
      catch
        kind, error ->
          Task.shutdown(task, :brutal_kill)
          :erlang.raise(kind, error, System.stacktrace())
      end
    end

    send(task.pid, ref)
    Task.await(task, :infinity)
  end

  defp migrated_successfully?(ref, pid) do
    receive do
      {^ref, :ok} -> true
      {^ref, _} -> false
      {:EXIT, ^pid, _} -> false
    end
  end

  defp run_maybe_in_transaction(parent, ref, repo, module, fun) do
    if module.__migration__[:disable_ddl_transaction] ||
         not repo.__adapter__.supports_ddl_transaction? do
      send_and_receive(parent, ref, fun.())
    else
      {:ok, result} =
        repo.transaction(
          fn -> send_and_receive(parent, ref, fun.()) end,
          log: false, timeout: :infinity
        )

      result
    end
  catch kind, reason ->
    send_and_receive(parent, ref, {kind, reason, System.stacktrace})
  end

  defp send_and_receive(parent, ref, value) do
    send parent, {ref, value}
    receive do: (^ref -> value)
  end

  defp attempt(repo, version, module, direction, operation, reference, opts) do
    if Code.ensure_loaded?(module) and
       function_exported?(module, operation, 0) do
      Runner.run(repo, version, module, direction, operation, reference, opts)
      :ok
    end
  end

  @doc """
  Runs migrations for the given repository.

  Equivalent to:

      Ecto.Migrator.run(repo, Ecto.Migrator.migrations_path(repo), direction, opts)

  See `run/4` for more information.
  """
  @spec run(Ecto.Repo.t, atom, Keyword.t) :: [integer]
  def run(repo, direction, opts) do
    run(repo, migrations_path(repo), direction, opts)
  end

  @doc ~S"""
  Apply migrations to a repository with a given strategy.

  The second argument identifies where the migrations are sourced from.
  A binary representing a directory may be passed, in which case we will
  load all files following the "#{VERSION}_#{NAME}.exs" schema. The
  `migration_source` may also be a list of a list of tuples that identify
  the version number and migration modules to be run, for example:

      Ecto.Migrator.run(Repo, [{0, MyApp.Migration1}, {1, MyApp.Migration2}, ...], :up, opts)

  A strategy (which is one of `:all`, `:step` or `:to`) must be given as
  an option.

  ## Execution model

  In order to run migrations, at least two database connections are
  necessary. One is used to lock the "schema_migrations" table and
  the other one to effectively run the migrations. This allows multiple
  nodes to run migrations at the same time, but guarantee that only one
  of them will effectively migrate the database.

  A downside of this approach is that migrations cannot run dynamically
  during test under the `Ecto.Adapters.SQL.Sandbox`, as the sandbox has
  to share a single connection across processes to guarantee the changes
  can be reverted.

  ## Options

    * `:all` - runs all available if `true`
    * `:step` - runs the specific number of migrations
    * `:to` - runs all until the supplied version is reached
    * `:log` - the level to use for logging. Defaults to `:info`.
      Can be any of `Logger.level/0` values or a boolean.
    * `:prefix` - the prefix to run the migrations on

  """
  @spec run(Ecto.Repo.t, binary | [{integer, module}], atom, Keyword.t) :: [integer]
  def run(repo, migration_source, direction, opts) do
    verbose_schema_migration repo, "create schema migrations table", fn ->
      SchemaMigration.ensure_schema_migrations_table!(repo, opts[:prefix])
    end

    lock_for_migrations repo, opts, fn versions ->
      cond do
        opts[:all] ->
          run_all(repo, versions, migration_source, direction, opts)
        to = opts[:to] ->
          run_to(repo, versions, migration_source, direction, to, opts)
        step = opts[:step] ->
          run_step(repo, versions, migration_source, direction, step, opts)
        true ->
          {:error, ArgumentError.exception("expected one of :all, :to, or :step strategies")}
      end
    end
  end

  @doc """
  Returns an array of tuples as the migration status of the given repo,
  without actually running any migrations.

  Equivalent to:

      Ecto.Migrator.migrations(repo, Ecto.Migrator.migrations_path(repo))

  """
  @spec migrations(Ecto.Repo.t) :: [{:up | :down, id :: integer(), name :: String.t}]
  def migrations(repo) do
    migrations(repo, migrations_path(repo))
  end

  @doc """
  Returns an array of tuples as the migration status of the given repo,
  without actually running any migrations.
  """
  @spec migrations(Ecto.Repo.t, String.t) :: [{:up | :down, id :: integer(), name :: String.t}]
  def migrations(repo, directory) do
    repo
    |> migrated_versions
    |> collect_migrations(directory)
    |> Enum.sort_by(fn {_, version, _} -> version end)
  end

  defp lock_for_migrations(repo, opts, fun) do
    query = SchemaMigration.versions(repo, opts[:prefix])
    meta = Ecto.Adapter.lookup_meta(repo)
    callback = &fun.(repo.all(&1, timeout: :infinity, log: false))

    case repo.__adapter__.lock_for_migrations(meta, query, opts, callback) do
      {kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)

      {:error, error} ->
        raise error

      result ->
        result
    end
  end

  defp run_to(repo, versions, migration_source, direction, target, opts) do
    within_target_version? = fn
      {version, _, _}, target, :up ->
        version <= target
      {version, _, _}, target, :down ->
        version >= target
    end

    pending_in_direction(versions, migration_source, direction)
    |> Enum.take_while(&(within_target_version?.(&1, target, direction)))
    |> migrate(direction, repo, opts)
  end

  defp run_step(repo, versions, migration_source, direction, count, opts) do
    pending_in_direction(versions, migration_source, direction)
    |> Enum.take(count)
    |> migrate(direction, repo, opts)
  end

  defp run_all(repo, versions, migration_source, direction, opts) do
    pending_in_direction(versions, migration_source, direction)
    |> migrate(direction, repo, opts)
  end

  defp pending_in_direction(versions, migration_source, :up) do
    migration_source
    |> migrations_for()
    |> Enum.filter(fn {version, _name, _file} -> not (version in versions) end)
  end

  defp pending_in_direction(versions, migration_source, :down) do
    migration_source
    |> migrations_for()
    |> Enum.filter(fn {version, _name, _file} -> version in versions end)
    |> Enum.reverse
  end

  defp collect_migrations(versions, migration_source) do
    ups_with_file =
      versions
      |> pending_in_direction(migration_source, :down)
      |> Enum.map(fn {version, name, _} -> {:up, version, name} end)

    ups_without_file =
      versions
      |> versions_without_file(migration_source)
      |> Enum.map(fn version -> {:up, version, "** FILE NOT FOUND **"} end)

    downs =
      versions
      |> pending_in_direction(migration_source, :up)
      |> Enum.map(fn {version, name, _} -> {:down, version, name} end)

    ups_with_file ++ ups_without_file ++ downs
  end

  defp versions_without_file(versions, migration_source) do
    versions_with_file =
      migration_source
      |> migrations_for()
      |> Enum.map(fn {version, _, _} -> version end)

    versions -- versions_with_file
  end

  # This function will match directories passed into `Migrator.run`.
  defp migrations_for(migration_source) when is_binary(migration_source) do
    query = Path.join(migration_source, "*")

    for entry <- Path.wildcard(query),
        info = extract_migration_info(entry),
        do: info
  end

  # This function will match specific version/modules passed into `Migrator.run`.
  defp migrations_for(migration_source) when is_list(migration_source) do
    Enum.map migration_source, fn {version, module} -> {version, module, module} end
  end

  defp extract_migration_info(file) do
    base = Path.basename(file)
    ext  = Path.extname(base)

    case Integer.parse(Path.rootname(base)) do
      {integer, "_" <> name} when ext == ".exs" ->
        {integer, name, file}
      _ ->
        nil
    end
  end

  defp migrate([], direction, _repo, opts) do
    level = Keyword.get(opts, :log, :info)
    log(level, "Already #{direction}")
    []
  end

  defp migrate(migrations, direction, repo, opts) do
    with :ok <- ensure_no_duplication(migrations),
         versions when is_list(versions) <- do_migrate(migrations, direction, repo, opts),
         do: Enum.reverse(versions)
  end

  defp do_migrate(migrations, direction, repo, opts) do
    migrations
    |> Enum.map(&load_migration/1)
    |> Enum.reduce_while([], fn {version, file_or_mod, modules}, versions ->
      with {:ok, mod} <- find_migration_module(modules, file_or_mod),
           :ok <- do_direction(direction, repo, version, mod, opts) do
        {:cont, [version | versions]}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp do_direction(:up, repo, version, mod, opts) do
    do_up(repo, version, mod, opts)
  end
  defp do_direction(:down, repo, version, mod, opts) do
    do_down(repo, version, mod, opts)
  end

  defp ensure_no_duplication([{version, name, _} | t]) do
    cond do
      List.keyfind(t, version, 0) ->
        message = "migrations can't be executed, migration version #{version} is duplicated"
        {:error, Ecto.MigrationError.exception(message)}

      List.keyfind(t, name, 1) ->
        message = "migrations can't be executed, migration name #{name} is duplicated"
        {:error, Ecto.MigrationError.exception(message)}

      true ->
        ensure_no_duplication(t)
    end
  end

  defp ensure_no_duplication([]), do: :ok

  defp find_migration_module(modules, file_or_mod) do
    cond do
      mod = Enum.find(modules, &function_exported?(&1, :__migration__, 0)) ->
        {:ok, mod}

      is_binary(file_or_mod) ->
        message = "file #{Path.relative_to_cwd(file_or_mod)} does not define an Ecto.Migration"
        {:error, Ecto.MigrationError.exception(message)}

      is_atom(file_or_mod) ->
        message = "module #{inspect(file_or_mod)} is not an Ecto.Migration"
        {:error, Ecto.MigrationError.exception(message)}
    end
  end

  defp load_migration({version, _, mod}) when is_atom(mod),
    do: {version, mod, [mod]}

  defp load_migration({version, _, file}) when is_binary(file),
    do: {version, file, Code.load_file(file) |> Enum.map(&elem(&1, 0))}

  defp verbose_schema_migration(repo, reason, fun) do
    try do
      fun.()
    rescue
      error ->
        Logger.error """
        Could not #{reason}. This error usually happens due to the following:

          * The database does not exist
          * The "schema_migrations" table, which Ecto uses for managing
            migrations, was defined by another library

        To fix the first issue, run "mix ecto.create".

        To address the second, you can run "mix ecto.drop" followed by
        "mix ecto.create". Alternatively you may configure Ecto to use
        another table for managing migrations:

            config #{inspect repo.config[:otp_app]}, #{inspect repo},
              migration_source: "some_other_table_for_schema_migrations"

        The full error report is shown below.
        """
        reraise error, System.stacktrace
    end
  end

  defp log(false, _msg), do: :ok
  defp log(level, msg),  do: Logger.log(level, msg)
end
