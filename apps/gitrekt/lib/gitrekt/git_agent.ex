defmodule GitRekt.GitAgent do
  @moduledoc ~S"""
  High-level API for running Git commands on a repository.

  This module provides an API to manipulate Git repositories. In contrast to `GitRekt.Git`, it offers
  an abstraction for serializing Git commands via message passing. By doing so it allows multiple processes
  to manipulate a single repository simultaneously (see “Thread safety” in `GitRekt.Git` module).

  At it core `GitRekt.GitAgent` implements `GenServer`. Therefore it makes it easy to fit into a supervision
  tree and furthermore, in a distributed environment.

  An other major benefit is support for caching command results. In their nature Git objects are immutable;
  that is, once they have been created and stored in the data store, they cannot be modified. This allows for
  very naive caching strategy implementations without having to deal with cache invalidation.

  ## Example

  Let's start by rewriting the example exposed in the `GitRekt.Git` module:

  ```elixir
  alias GitRekt.GitAgent

  # load repository
  {:ok, agent} = GitAgent.start_link("tmp/my-repo.git")

  # fetch master branch
  {:ok, branch} = GitAgent.branch(agent, "master")

  # fetch commit pointed by master
  {:ok, commit} = GitAgent.peel(agent, branch)

  # fetch commit author & message
  {:ok, author} = GitAgent.commit_author(agent, commit)
  {:ok, message} = GitAgent.commit_message(agent, commit)

  IO.puts "Last commit by #{author.name} <#{author.email}>:"
  IO.puts message
  ```

  This look very similar to the original example altought the API slightly differs.

  You might have noticed that the first argument of each Git function is `agent`. In our example the agent is
  a PID referencing a dedicated process started with `start_link/1`.

  Note that replacing `start_link/1` with `GitRekt.Git.repository_open/1` would print the exact same output.
  This works because `t:agent/0` can be either a process id (PID) or a `t:GitRekt.Git.repo/0`.

  ## Cache

  `GitRekt.GitAgent` implements a very basic caching mechanism built on top of Erlang Term Storage (ETS).

  When a Git command is executed successfully, the agent is able to cache the result of the command.
  Further calls will retrieve results from the cache without having to run low-level `GitRekt.Git` functions.

  We'll use `history_count/2` as an example because it is a relatively expensive operation:

  ```
  # fetch commit for HEAD
  {:ok, head} = GitAgent.head(agent)
  {:ok, commit} = GitAgent.peel(agent, head)

  # count the number of ancestors and store result to cache
  {:ok, count} = GitAgent.history_count(agent, commit)

  # same thing, but retrieve result from cache
  {:ok, count} = GitAgent.history_count(agent, commit)
  ```

  Here's the corresponding log output:

  ```log
  [debug] [Git Agent] head() executed in 95 µs
  [debug] [Git Agent] peel(<GitRef:refs/heads/master>, :commit) executed in 41 µs
  [debug] [Git Agent] history_count(<GitCommit:fad48c4>) executed in 568.0 ms
  [debug] [Git Agent] history_count(<GitCommit:fad48c4>) executed in ⚡ 3 µs
  ```

  We can clearly see that the second call only need a fraction of the time to return.

  Note that the default implemententation is quite restrictive and only caches expensive operations and
  explicitly named transactions (more on that later).

  See `GitRekt.Cache` for more details on how to implement your own caching behaviour.

  ## Transactions

  You can execute a serie of commands inside a transaction.

  In the following example, we use `transaction/2` to retrieve all informations for a given commit:

  ```
  GitAgent.transaction(agent, fn agent ->
    with {:ok, author} <- GitAgent.commit_author(agent, commit),
        {:ok, committer} <- GitAgent.commit_committer(agent, commit),
        {:ok, message} <- GitAgent.commit_message(agent, commit),
        {:ok, parents} <- GitAgent.commit_parents(agent, commit),
        {:ok, timestamp} <- GitAgent.commit_timestamp(agent, commit),
        {:ok, gpg_sig} <- GitAgent.commit_gpg_signature(agent, commit) do
      {:ok, %{
        oid: commit.oid,
        author: author,
        committer: committer,
        message: message,
        parents: Enum.to_list(parents),
        timestamp: timestamp,
        gpg_sig: gpg_sig
      }}
    end
  end)
  ```

  Transactions provide a simple entry point for implementing more complex commands. The function is
  executed by the agent in a single request; avoiding the costs of making six consecutive `GenServer.call/3`.

  You can also use transactions to cache the result of a serie of commands. Let's wrap our previous example
  in a function and give the transaction an unique identifier.

  ```
  def commit_info(agent, commit) do
    # identifier: {:commit_info, oid}
    GitAgent.transaction(agent, {:commit_info, commit.oid}, fn agent -> ... end)
  end
  ```

  By using a unique identifier, we tell `GitRekt.GitAgent` that the result of our function should be cached.

  Here's the log output for two consecutive `commit_info/2` calls:

  ```log
  [debug] [Git Agent] transaction(:commit_info, "b662d32") executed in 361 µs
  [debug] [Git Agent] | commit_author(<GitCommit:b662d32>) executed in 6 µs
  [debug] [Git Agent] | commit_committer(<GitCommit:b662d32>) executed in 5 µs
  [debug] [Git Agent] | commit_message(<GitCommit:b662d32>) executed in 1 µs
  [debug] [Git Agent] | commit_parents(<GitCommit:b662d32>) executed in 4 µs
  [debug] [Git Agent] | commit_timestamp(<GitCommit:b662d32>) executed in 11 µs
  [debug] [Git Agent] | commit_gpg_signature(<GitCommit:b662d32>) executed in 6 µs
  [debug] [Git Agent] transaction(:commit_info, "b662d32") executed in ⚡ 3 µs
  ```

  We can observe that the first call executes the different commands one by one and cache the result while
  the second one fetches the result directly from the cache without having to actually run the transaction.

  Note that `transaction/3` can be called recursively and still benefit from caching.
  """
  use GenServer

  alias GitRekt.{
    Git,
    GitRepo,
    GitOdb,
    GitCommit,
    GitRef,
    GitTag,
    GitBlob,
    GitTree,
    GitTreeEntry,
    GitIndex,
    GitIndexEntry,
    GitDiff
  }

  @behaviour GitRekt.Cache

  @type agent :: pid | Git.repo

  @type git_object :: GitCommit.t | GitBlob.t | GitTree.t | GitTag.t
  @type git_revision :: GitRef.t | GitTag.t | GitCommit.t

  @default_config %{
      stream_chunk_size: 1_000,
      timeout: 5_000,
      idle_timeout: :infinity
  }

  @exec_opts [:timeout]

  @doc """
  Starts a Git agent linked to the current process for the repository at the given `path`.
  """
  @spec start_link(Path.t, keyword) :: GenServer.on_start
  def start_link(path, opts \\ []) do
    {agent_opts, server_opts} = Keyword.split(opts, Map.keys(@default_config))
    GenServer.start_link(__MODULE__, {path, agent_opts}, server_opts)
  end

  @spec unwrap(GitRepo.t) :: {:ok, agent} | {:error, term}
  defdelegate unwrap(repo), to: GitRepo, as: :get_agent

  @doc """
  Returns `true` if the repository is empty; otherwise returns `false`.
  """
  @spec empty?(agent, keyword) :: {:ok, boolean} | {:error, term}
  def empty?(agent, opts \\ []), do: exec(agent, :empty?, opts)


  @doc """
  Returns the ODB.
  """
  @spec odb(agent, keyword) :: {:ok, GitOdb.t}
  def odb(agent, opts \\ []), do: exec(agent, :odb, opts)

  @doc """
  Return the raw data of the `odb` object with the given `oid`.
  """
  @spec odb_read(agent, GitOdb.t, Git.oid, keyword) :: {:ok, {Git.obj_type, binary}} | {:error, term}
  def odb_read(agent, odb, oid, opts \\ []), do: exec(agent, {:odb_read, odb, oid}, opts)

  @doc """
  Writes the given `data` into the `odb`.
  """
  @spec odb_write(agent, GitOdb.t, binary, atom, keyword) :: {:ok, Git.oid} | {:error, term}
  def odb_write(agent, odb, data, type, opts \\ []), do: exec(agent, {:odb_write, odb, data, type}, opts)

  @doc """
  Returns `true` if the given `oid` exists in `odb`; elsewise returns `false`.
  """
  @spec odb_object_exists?(agent, GitOdb.t, Git.oid, keyword) :: {:ok, boolean} | {:error, term}
  def odb_object_exists?(agent, odb, oid, opts \\ []), do: exec(agent, {:odb_object_exists?, odb, oid}, opts)

  @doc """
  Returns the Git reference for `HEAD`.
  """
  @spec head(agent, keyword) :: {:ok, GitRef.t} | {:error, term}
  def head(agent, opts \\ []), do: exec(agent, :head, opts)

  @doc """
  Returns all Git branches.
  """
  @spec branches(agent, keyword) :: {:ok, Enumerable.t} | {:error, term}
  def branches(agent, opts \\ [])do
    {exec_opts, opts} = pop_exec_opts(opts)
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:references, "refs/heads/*", opts}, exec_opts),
    else: exec(agent, {:references_with, with_target, "refs/heads/*", opts}, exec_opts)
  end

  @doc """
  Returns the Git branch with the given `name`.
  """
  @spec branch(agent, binary, keyword) :: {:ok, GitRef.t | {GitRef.t, GitCommit.t}} | {:error, term}
  def branch(agent, name, opts \\ []) do
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:reference, "refs/heads/" <> name, :undefined}, opts),
    else: exec(agent, {:reference_with, with_target, "refs/heads/" <> name}, opts)
  end

  @doc """
  Returns all Git tags.
  """
  @spec tags(agent, keyword) :: {:ok, Enumerable.t} | {:error, term}
  def tags(agent, opts \\ []) do
    {exec_opts, opts} = pop_exec_opts(opts)
    {with_target, opts} = Keyword.pop(opts, :with)
    opts = Keyword.put(opts, :target, :tag)
    unless with_target,
      do: exec(agent, {:references, "refs/tags/*", opts}, exec_opts),
    else: exec(agent, {:references_with, with_target, "refs/tags/*", opts}, exec_opts)
  end

  @doc """
  Returns the Git tag with the given `name`.
  """
  @spec tag(agent, binary, keyword) :: {:ok, GitRef.t | GitTag.t | {GitRef.t | GitTag.t, GitCommit.t}} | {:error, term}
  def tag(agent, name, opts \\ []) do
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:reference, "refs/tags/" <> name, :tag}, opts),
    else: exec(agent, {:reference_with, with_target, "refs/tags/" <> name, :tag}, opts)
  end

  @doc """
  Returns the Git tag author of the given `tag`.
  """
  @spec tag_author(agent, GitTag.t, keyword) :: {:ok, map} | {:error, term}
  def tag_author(agent, tag, opts \\ []), do: exec(agent, {:tag_author, tag}, opts)

  @doc """
  Returns the Git tag message of the given `tag`.
  """
  @spec tag_message(agent, GitTag.t, keyword) :: {:ok, binary} | {:error, term}
  def tag_message(agent, tag, opts \\ []), do: exec(agent, {:tag_message, tag}, opts)

  @doc """
  Returns all Git references matching the given `glob`.
  """
  @spec references(agent, keyword) :: {:ok, Enumerable.t} | {:error, term}
  def references(agent, opts \\ []) do
    {exec_opts, opts} = pop_exec_opts(opts)
    {glob, opts} = Keyword.pop(opts, :glob, :undefined)
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:references, glob, opts}, exec_opts),
    else: exec(agent, {:references_with, with_target, glob, opts}, exec_opts)
  end

  @doc """
  Returns the Git reference with the given `name`.
  """
  @spec reference(agent, binary, keyword) :: {:ok, GitRef.t | {GitRef.t, GitCommit.t}} | {:error, term}
  def reference(agent, name, opts \\ []) do
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:reference, name, :undefined}, opts),
    else: exec(agent, {:reference_with, with_target, name, :undefined}, opts)
  end

  @doc """
  Creates a reference with the given `name` and `target`.
  """
  @spec reference_create(agent, binary, atom, Git.oid | binary, keyword) :: :ok | {:error, term}
  def reference_create(agent, name, type, target, opts \\ []) do
    {force, opts} = Keyword.pop(opts, :force, false)
    exec(agent, {:reference_create, name, type, target, force}, opts)
  end

  @doc """
  Deletes a reference with the given `name`.
  """
  @spec reference_delete(agent, binary, keyword) :: :ok | {:error, term}
  def reference_delete(agent, name, opts \\ []), do: exec(agent, {:reference_delete, name}, opts)

  @doc """
  Returns the number of unique commits between two commit objects.
  """
  @spec graph_ahead_behind(agent, Git.oid, Git.oid, keyword) :: {:ok, {non_neg_integer, non_neg_integer}} | {:error, term}
  def graph_ahead_behind(agent, local, upstream, opts \\ []), do: exec(agent, {:graph_ahead_behind, local, upstream}, opts)

  @doc """
  Returns the Git object with the given `oid`.
  """
  @spec object(agent, Git.oid, keyword) :: {:ok, git_object} | {:error, term}
  def object(agent, oid, opts \\ []), do: exec(agent, {:object, oid}, opts)

  @doc """
  Returns the Git object matching the given `spec`.
  """
  @spec revision(agent, binary, keyword) :: {:ok, {GitRef.t | GitTag.t, GitCommit.t | nil}} | {:error, term}
  def revision(agent, spec, opts \\ []), do: exec(agent, {:revision, spec}, opts)

  @doc """
  Returns the author of the given `commit`.
  """
  @spec commit_author(agent, GitCommit.t, keyword) :: {:ok, map} | {:error, term}
  def commit_author(agent, commit, opts \\ []), do: exec(agent, {:commit_author, commit}, opts)

  @doc """
  Returns the committer of the given `commit`.
  """
  @spec commit_committer(agent, GitCommit.t, keyword) :: {:ok, map} | {:error, term}
  def commit_committer(agent, commit, opts \\ []), do: exec(agent, {:commit_committer, commit}, opts)

  @doc """
  Returns the message of the given `commit`.
  """
  @spec commit_message(agent, GitCommit.t, keyword) :: {:ok, binary} | {:error, term}
  def commit_message(agent, commit, opts \\ []), do: exec(agent, {:commit_message, commit}, opts)

  @doc """
  Returns the timestamp of the given `commit`.
  """
  @spec commit_timestamp(agent, GitCommit.t, keyword) :: {:ok, DateTime.t} | {:error, term}
  def commit_timestamp(agent, commit, opts \\ []), do: exec(agent, {:commit_timestamp, commit}, opts)

  @doc """
  Returns the parent of the given `commit`.
  """
  @spec commit_parents(agent, GitCommit.t, keyword) :: {:ok, Enumerable.t} | {:error, term}
  def commit_parents(agent, commit, opts \\ []) do
    {exec_opts, opts} = pop_exec_opts(opts)
    exec(agent, {:commit_parents, commit, opts}, exec_opts)
  end

  @doc """
  Returns the GPG signature of the given `commit`.
  """
  @spec commit_gpg_signature(agent, GitCommit.t, keyword) :: {:ok, binary} | {:error, term}
  def commit_gpg_signature(agent, commit, opts \\ []), do: exec(agent, {:commit_gpg_signature, commit}, opts)

  @doc """
  Creates a commit with the given `tree_oid` and `parents_oid`.
  """
  @spec commit_create(agent, map, map, binary, Git.oid, [Git.oid], keyword) :: {:ok, Git.oid} | {:error, term}
  def commit_create(agent, author, committer, message, tree_oid, parents_oids, opts \\ []) do
    {update_ref, opts} = Keyword.pop(opts, :update_ref, :undefined)
    exec(agent, {:commit_create, update_ref, author, committer, message, tree_oid, parents_oids}, opts)
  end

  @doc """
  Returns the content of the given `blob`.
  """
  @spec blob_content(agent, GitBlob.t, keyword) :: {:ok, binary} | {:error, term}
  def blob_content(agent, blob, opts \\ []), do: exec(agent, {:blob_content, blob}, opts)

  @doc """
  Returns the size in byte of the given `blob`.
  """
  @spec blob_size(agent, GitBlob.t, keyword) :: {:ok, non_neg_integer} | {:error, term}
  def blob_size(agent, blob, opts \\ []), do: exec(agent, {:blob_size, blob}, opts)

  @doc """
  Returns the Git tree of the given `revision`.
  """
  @spec tree(agent, git_revision, keyword) :: {:ok, GitTree.t} | {:error, term}
  def tree(agent, revision, opts \\ []), do: exec(agent, {:tree, revision}, opts)

  @doc """
  Returns the Git tree entry for the given `revision` and `oid`.
  """
  @spec tree_entry_by_id(agent, git_revision | GitTree.t, Git.oid, keyword) :: {:ok, GitTreeEntry.t} | {:error, term}
  def tree_entry_by_id(agent, revision, oid, opts \\ []) do
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:tree_entry, revision, {:oid, oid}}, opts),
    else: exec(agent, {:tree_entry_with, with_target, revision, {:oid, oid}}, opts)
  end

  @doc """
  Returns the Git tree entry for the given `revision` and `path`.
  """
  @spec tree_entry_by_path(agent, git_revision | GitTree.t, Path.t, keyword) :: {:ok, GitTreeEntry.t | {GitTreeEntry.t, GitCommit.t}} | {:error, term}
  def tree_entry_by_path(agent, revision, path, opts \\ []) do
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:tree_entry, revision, {:path, path}}, opts),
    else: exec(agent, {:tree_entry_with, with_target, revision, {:path, path}}, opts)
  end

  @doc """
  Returns the Git tree entries of the given `tree`.
  """
  @spec tree_entries(agent, git_revision | GitTree.t, keyword) :: {:ok, Enumerable.t} | {:error, term}
  def tree_entries(agent, revision, opts \\ []) do
    {exec_opts, opts} = pop_exec_opts(opts)
    {path, opts} = Keyword.pop(opts, :path, :root)
    {with_target, opts} = Keyword.pop(opts, :with)
    unless with_target,
      do: exec(agent, {:tree_entries, revision, path, opts}, exec_opts),
    else: exec(agent, {:tree_entries_with, with_target, revision, path, opts}, exec_opts)
  end

  @doc """
  Returns the Git index of the repository.
  """
  @spec index(agent, keyword) :: {:ok, GitIndex.t} | {:error, term}
  def index(agent, opts \\ []), do: exec(agent, :index, opts)

  @doc """
  Adds `index_entry` to the gieven `index`.
  """
  @spec index_add(agent, GitIndex.t, GitIndexEntry.t, keyword) :: :ok | {:error, term}
  def index_add(agent, index, index_entry, opts \\ []), do: exec(agent, {:index_add, index, index_entry}, opts)

  @doc """
  Adds an index entry to the given `index`.
  """
  @spec index_add(agent, GitIndex.t, Git.oid, Path.t, non_neg_integer, pos_integer, keyword) :: :ok | {:error, term}
  def index_add(agent, index, oid, path, file_size, mode, opts \\ []), do: exec(agent, {:index_add, index, oid, path, file_size, mode, opts}, opts)

  @doc """
  Removes an index entry from the given `index`.
  """
  @spec index_remove(agent, GitIndex.t, Path.t, keyword) :: :ok | {:error, term}
  def index_remove(agent, index, path, opts \\ []), do: exec(agent, {:index_remove, index, path}, opts)

  @doc """
  Remove all entries from the given `index` under a given directory `path`.
  """
  @spec index_remove_dir(agent, GitIndex.t, Path.t, keyword) :: :ok | {:error, term}
  def index_remove_dir(agent, index, path, opts \\ []), do: exec(agent, {:index_remove_dir, index, path}, opts)

  @doc """
  Reads the given `tree` into the given `index`.
  """
  @spec index_read_tree(agent, GitIndex.t, GitTree.t, keyword) :: :ok | {:error, term}
  def index_read_tree(agent, index, tree, opts \\ []), do: exec(agent, {:index_read_tree, index, tree}, opts)

  @doc """
  Writes the given `index` as a tree.
  """
  @spec index_write_tree(agent, GitIndex.t, keyword) :: {:ok, Git.oid} | {:error, term}
  def index_write_tree(agent, index, opts \\ []), do: exec(agent, {:index_write_tree, index}, opts)

  @doc """
  Returns the Git diff of `obj1` and `obj2`.
  """
  @spec diff(agent, git_revision | GitTree.t, git_revision | GitTree.t, keyword) :: {:ok, GitDiff.t} | {:error, term}
  def diff(agent, obj1, obj2, opts \\ []), do: exec(agent, {:diff, obj1, obj2, opts}, opts)

  @doc """
  Returns the deltas of the given `diff`.
  """
  @spec diff_deltas(agent, GitDiff.t, keyword) :: {:ok, map} | {:error, term}
  def diff_deltas(agent, diff, opts \\ []), do: exec(agent, {:diff_deltas, diff}, opts)

  @doc """
  Returns a binary formated representation of the given `diff`.
  """
  @spec diff_format(agent, GitDiff.t, keyword) :: {:ok, binary} | {:error, term}
  def diff_format(agent, diff, opts \\ []) do
    {format, opts} = Keyword.pop(opts, :patch)
    exec(agent, {:diff_format, diff, format}, opts)
  end

  @doc """
  Returns the stats of the given `diff`.
  """
  @spec diff_stats(agent, GitDiff.t, keyword) :: {:ok, map} | {:error, term}
  def diff_stats(agent, diff, opts \\ []), do: exec(agent, {:diff_stats, diff}, opts)

  @doc """
  Returns the Git commit history of the given `revision`.
  """
  @spec history(agent, git_revision, keyword) :: {:ok, Enumerable.t} | {:error, term}
  def history(agent, revision, opts \\ []) do
    {exec_opts, opts} = pop_exec_opts(opts)
    exec(agent, {:history, revision, opts}, exec_opts)
  end

  @doc """
  Returns the number of commit ancestors for the given `revision`.
  """
  @spec history_count(agent, git_revision, keyword) :: {:ok, non_neg_integer} | {:error, term}
  def history_count(agent, revision, opts \\ []), do: exec(agent, {:history_count, revision}, opts)

  @doc """
  Peels the given `obj` until a Git object of the specified type is met.
  """
  @spec peel(agent, git_revision | GitTreeEntry.t, keyword) :: {:ok, git_object} | {:error, term}
  def peel(agent, obj, opts \\ []) do
    {target, opts} = Keyword.pop(opts, :target, :undefined)
    exec(agent, {:peel, obj, target}, opts)
  end

  @doc """
  Returns a Git PACK representation of the given `oids`.
  """
  @spec pack_create(agent, [Git.oid], keyword) :: {:ok, binary} | {:error, term}
  def pack_create(agent, oids, opts \\ []), do: exec(agent, {:pack, oids}, opts)

  @doc """
  Executes the given `cb` inside a transaction.
  """
  @spec transaction(agent, term, (Git.repo -> {:ok, term} | {:error, term}), keyword) :: {:ok, term} | {:error, term}
  def transaction(agent, name \\ nil, cb, opts \\ []) do
    exec(agent, {:transaction, name, cb}, opts)
  end

  #
  # Callbacks
  #

  @impl true
  def init({path, opts}) do
    case Git.repository_open(path) do
      {:ok, handle} ->
        config = Map.merge(@default_config, Map.new(opts))
        config = Map.put(config, :cache, init_cache(path, []))
        {:ok, {handle, config}, config.idle_timeout}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def init_cache(_path, opts), do: :ets.new(__MODULE__, [:set, :protected] ++ opts)

  @impl true
  def fetch_cache(cache, op) when not is_nil(op) do
    case :ets.lookup(cache, op) do
      [{^op, cache_entry}] ->
        cache_entry
      [] ->
        nil
    end
  end

  @impl true
  def put_cache(cache, op, resp) when not is_nil(op) do
    :ets.insert(cache, {op, resp})
    :ok
  end

  @impl true
  def handle_call({:references, glob, opts}, _from, {handle, config} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, config.stream_chunk_size)
    {:reply, call_stream(handle, {:references, glob, opts}, chunk_size), state, config.idle_timeout}
  end

  def handle_call({:references_with, with_target, glob, opts}, _from, {handle, config} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, config.stream_chunk_size)
    {:reply, call_stream(handle, {:references_with, with_target, glob, opts}, chunk_size), state, config.idle_timeout}
  end

  def handle_call({:history, obj, opts}, _from, {handle, config} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, config.stream_chunk_size)
    {:reply, call_stream(handle, {:history, obj, opts}, chunk_size), state, config.idle_timeout}
  end

  def handle_call({:tree_entries, tree, opts}, _from, {handle, config} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, config.stream_chunk_size)
    {:reply, call_stream(handle, {:tree_entries, tree, opts}, chunk_size), state, config.idle_timeout}
  end

  def handle_call({:tree_entries, rev, path, opts}, _from, {handle, config} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, config.stream_chunk_size)
    {:reply, call_stream(handle, {:tree_entries, rev, path, opts}, chunk_size), state, config.idle_timeout}
  end

  def handle_call({:tree_entries_with, with_target, rev, path, opts}, _from, {handle, config} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, config.stream_chunk_size)
    {:reply, call_stream(handle, {:tree_entries_with, with_target, rev, path, opts}, chunk_size), state, config.idle_timeout}
  end

  def handle_call({:commit_parents, commit, opts}, _from, {handle, config} = state) do
    {chunk_size, opts} = Keyword.pop(opts, :stream_chunk_size, config.stream_chunk_size)
    {:reply, call_stream(handle, {:commit_parents, commit, opts}, chunk_size), state, config.idle_timeout}
  end

  def handle_call({:stream_next, stream, chunk_size}, _from, {_handle, config} = state) do
    {head, tail} = StreamSplit.take_and_drop(stream, chunk_size)
    if length(head) == chunk_size,
      do: {:reply, {head, tail}, state, config.idle_timeout},
    else: {:reply, {head, :halt}, state, config.idle_timeout}
  end

  def handle_call(op, _from, {handle, %{cache: cache} = config} = state) do
    {:reply, call_cache(handle, op, cache), state, config.idle_timeout}
  end

  @impl true
  def handle_info(:timeout, {_handle, %{idle_timeout: :infinity}} = state) do
    {:noreply, state}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def make_cache_key({:history_count, %GitRef{oid: oid}}), do: {:history_count, oid}
  def make_cache_key({:history_count, %GitCommit{oid: oid}}), do: {:history_count, oid}
  def make_cache_key({:transaction, name, _cb}) when not is_nil(name), do: {:transaction, name}
  def make_cache_key(_op), do: nil

  #
  # Helpers
  #

  defp exec(agent, op, opts) when is_pid(agent), do: GenServer.call(agent, op, Keyword.get(opts, :timeout, @default_config.timeout))
  defp exec(agent, op, _opts) when is_reference(agent), do: call(agent, op)
  defp exec({agent, cache}, op, _opts) when is_reference(agent), do: call_cache(agent, op, cache)

  defp pop_exec_opts(opts), do: Enum.split_with(opts, fn {k, _v} -> k in @exec_opts end)

  defp call(handle, :empty?) do
    {:ok, Git.repository_empty?(handle)}
  end

  defp call(handle, :head) do
    case Git.reference_resolve(handle, "HEAD") do
      {:ok, name, shorthand, oid} ->
        {:ok, resolve_reference({name, shorthand, :oid, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, {:references, glob, opts}) do
    case Git.reference_stream(handle, glob) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &resolve_reference_peel!(&1, Keyword.get(opts, :target, :undefined), handle))}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, {:references_with, with_target, glob, opts}) do
    case Git.reference_stream(handle, glob) do
      {:ok, stream} ->
        stream = Stream.map(stream, &resolve_reference_peel!(&1, Keyword.get(opts, :target, :undefined), handle))
        stream = Stream.map(stream, &{&1, resolve_peel!(&1, with_target, handle)})
        {:ok, stream}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, {:reference, "refs/" <> _suffix = name, target}) do
    case Git.reference_lookup(handle, name) do
      {:ok, shorthand, :oid, oid} ->
        fetch_reference_target({name, shorthand, :oid, oid}, target, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, {:reference, shorthand, target}) do
    case Git.reference_dwim(handle, shorthand) do
      {:ok, name, :oid, oid} ->
        fetch_reference_target({name, shorthand, :oid, oid}, target, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, {:reference_with, with_target, "refs/" <> _suffix = name, target}) do
    with {:ok, shorthand, :oid, oid} <- Git.reference_lookup(handle, name),
         {:ok, ref} <- fetch_reference_target({name, shorthand, :oid, oid}, target, handle),
         {:ok, target} <- fetch_target(ref, with_target, handle), do:
      {:ok, {ref, target}}
  end

  defp call(handle, {:reference_with, with_target, shorthand, target}) do
    with {:ok, name, :oid, oid} <- Git.reference_dwim(handle, shorthand),
         {:ok, ref} <- fetch_reference_target({name, shorthand, :oid, oid}, target, handle),
         {:ok, target} <- fetch_target(ref, with_target, handle), do:
      {:ok, {ref, target}}
  end

  defp call(handle, {:reference_create, name, type, target, force}), do: Git.reference_create(handle, name, type, target, force)
  defp call(handle, {:reference_delete, name}), do: Git.reference_delete(handle, name)

  defp call(handle, {:revision, spec}) do
    case Git.revparse_ext(handle, spec) do
      {:ok, obj, obj_type, oid, name} ->
        {:ok, {resolve_object({obj, obj_type, oid}), resolve_reference({name, nil, :oid, oid})}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, {:graph_ahead_behind, local, upstream}) do
    case Git.graph_ahead_behind(handle, local, upstream) do
      {:ok, ahead, behind} ->
        {:ok, {ahead, behind}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, :odb) do
    case Git.repository_get_odb(handle) do
      {:ok, odb} ->
        {:ok, resolve_odb(odb)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(_handle, {:odb_read, %GitOdb{__ref__: odb}, oid}) do
    case Git.odb_read(odb, oid) do
      {:ok, obj_type, obj_data} ->
        {:ok, {obj_type, obj_data}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(_handle, {:odb_write, %GitOdb{__ref__: odb}, data, type}), do: Git.odb_write(odb, data, type)
  defp call(_handle, {:odb_object_exists?, %GitOdb{__ref__: odb}, oid}) do
    {:ok, Git.odb_object_exists?(odb, oid)}
  end

  defp call(handle, {:object, oid}) do
    case Git.object_lookup(handle, oid) do
      {:ok, obj_type, obj} ->
        {:ok, resolve_object({obj, obj_type, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(_handle, {:tag_author, obj}), do: fetch_author(obj)
  defp call(_handle, {:tag_message, obj}), do: fetch_author(obj)

  defp call(_handle, {:commit_author, obj}), do: fetch_author(obj)
  defp call(_handle, {:commit_committer, obj}), do: fetch_committer(obj)
  defp call(_handle, {:commit_message, obj}), do: fetch_message(obj)
  defp call(_handle, {:commit_parents, %GitCommit{__ref__: commit}, _opts}) do
    case Git.commit_parents(commit) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &resolve_commit_parent/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(_handle, {:commit_timestamp, %GitCommit{__ref__: commit}}) do
    case Git.commit_time(commit) do
      {:ok, time, _offset} ->
        DateTime.from_unix(time)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(_handle, {:commit_gpg_signature, %GitCommit{__ref__: commit}}), do: Git.commit_header(commit, "gpgsig")
  defp call(handle, {:commit_create, update_ref, author, committer, message, tree_oid, parents_oids}) do
    Git.commit_create(
      handle,
      update_ref,
      signature_tuple(author),
      signature_tuple(committer),
      :undefined,
      message,
      tree_oid,
      List.wrap(parents_oids)
    )
  end

  defp call(handle, {:tree, obj}), do: fetch_tree(obj, handle)
  defp call(handle, {:tree_entry, obj, spec}), do: fetch_tree_entry(obj, spec, handle)
  defp call(handle, {:tree_entry_with, with_target, obj, spec}) do
    with {:ok, tree_entry} <- fetch_tree_entry(obj, spec, handle),
         {:ok, target} <- fetch_tree_entry_target(with_target, obj, spec, handle), do:
      {:ok, {tree_entry, target}}
  end

  defp call(handle, {:tree_entries, tree, _opts}), do: fetch_tree_entries(tree, handle)
  defp call(handle, {:tree_entries, rev, :root, _opts}), do: fetch_tree_entries(rev, handle)
  defp call(handle, {:tree_entries, rev, path, _opts}), do: fetch_tree_entries(rev, path, handle)
  defp call(handle, {:tree_entries_with, with_target, rev, :root, _opts}) do
    with {:ok, tree_entries} <- fetch_tree_entries(rev, handle),
         {:ok, commits} <- walk_history(rev, handle), do:
      {:ok, Stream.transform(commits, Map.new(tree_entries, &{&1.name, &1}), &zip_tree_entries_target(with_target, &1, &2, handle))}
  end

  defp call(handle, {:tree_entries_with, with_target, rev, path, _opts}) do
    with {:ok, root_tree_entry} <- fetch_tree_entry(rev, {:path, path}, handle),
         {:ok, tree_entries} <- fetch_tree_entries(rev, path, handle),
         {:ok, commits} <- walk_history(rev, handle, pathspec: path), do:
      {:ok, Stream.transform(commits, {root_tree_entry, Map.new(tree_entries, &{Path.join(path, &1.name), &1})}, &zip_tree_entries_target(with_target, &1, &2, handle))}
  end

  defp call(_handle, {:blob_content, %GitBlob{__ref__: blob}}), do: Git.blob_content(blob)
  defp call(_handle, {:blob_size, %GitBlob{__ref__: blob}}), do: Git.blob_size(blob)

  defp call(handle, {:diff, obj1, obj2, opts}), do: fetch_diff(obj1, obj2, handle, opts)
  defp call(_handle, {:diff_format, %GitDiff{__ref__: diff}, format}), do: Git.diff_format(diff, format)
  defp call(_handle, {:diff_deltas, %GitDiff{__ref__: diff}}) do
    case Git.diff_deltas(diff) do
      {:ok, deltas} ->
        {:ok, Enum.map(deltas, &resolve_diff_delta/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(_handle, {:diff_stats, %GitDiff{__ref__: diff}}) do
    case Git.diff_stats(diff) do
      {:ok, files_changed, insertions, deletions} ->
        {:ok, resolve_diff_stats({files_changed, insertions, deletions})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, :index) do
    case Git.repository_get_index(handle) do
      {:ok, index} -> {:ok, resolve_index(index)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call(_handle, {:index_add, %GitIndex{__ref__: index}, %GitIndexEntry{} = entry}) do
    Git.index_add(index, {
      entry.ctime,
      entry.mtime,
      entry.dev,
      entry.ino,
      entry.mode,
      entry.uid,
      entry.gid,
      entry.file_size,
      entry.oid,
      entry.flags,
      entry.flags_extended,
      entry.path
    })
  end

  defp call(_handle, {:index_add, %GitIndex{__ref__: index}, oid, path, file_size, mode, opts}) do
    tree_entry = {
      Keyword.get(opts, :ctime, :undefined),
      Keyword.get(opts, :mtime, :undefined),
      Keyword.get(opts, :dev, :undefined),
      Keyword.get(opts, :ino, :undefined),
      mode,
      Keyword.get(opts, :uid, :undefined),
      Keyword.get(opts, :gid, :undefined),
      file_size,
      oid,
      Keyword.get(opts, :flags, :undefined),
      Keyword.get(opts, :flags_extended, :undefined),
      path
    }
    Git.index_add(index, tree_entry)
  end

  defp call(_handle, {:index_remove, %GitIndex{__ref__: index}, path}), do: Git.index_remove(index, path)
  defp call(_handle, {:index_remove_dir, %GitIndex{__ref__: index}, path}), do: Git.index_remove_dir(index, path)
  defp call(_handle, {:index_read_tree, %GitIndex{__ref__: index}, %GitTree{__ref__: tree}}), do: Git.index_read_tree(index, tree)
  defp call(handle, {:index_write_tree, %GitIndex{__ref__: index}}), do: Git.index_write_tree(index, handle)

  defp call(handle, {:history, rev, opts}), do: walk_history(rev, handle, opts)
  defp call(handle, {:history_count, rev}) do
    case walk_history(rev, handle) do
      {:ok, stream} ->
        {:ok, Enum.count(stream)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(handle, {:peel, obj, target}), do: fetch_target(obj, target, handle)

  defp call(handle, {:pack, oids}) do
    with {:ok, walk} <- Git.revwalk_new(handle),
          :ok <- walk_insert(walk, oid_mask(oids)),
      do: Git.revwalk_pack(walk)
  end

  defp call(handle, {:transaction, _name, cb}), do: cb.(handle)

  defp call_cache(handle, {:transaction, _name, _cb} = op, cache) when not is_tuple(handle) do
    call_cache({handle, cache}, op, cache)
  end

  defp call_cache(handle, op, cache) do
    cache_adapter = Keyword.get(Application.get_env(:gitrekt, __MODULE__, []), :cache_adapter, __MODULE__)
    if cache_key = cache_adapter.make_cache_key(op) do
      event_time = System.monotonic_time(:microsecond)
      if cache_result = cache_adapter.fetch_cache(cache, cache_key) do
        telemetry(:execute, op, %{duration: System.monotonic_time(:microsecond) - event_time}, %{cache: cache_key})
        {:ok, cache_result}
      else
        case call(handle, op) do
          :ok ->
            telemetry(:execute, op, %{duration: System.monotonic_time(:microsecond) - event_time})
            :ok
          {:ok, result} ->
            telemetry(:execute, op, %{duration: System.monotonic_time(:microsecond) - event_time})
            cache_adapter.put_cache(cache, cache_key, result)
            {:ok, result}
          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      telemetry(:execute, op, fn -> call(handle, op) end)
    end
  end

  defp call_stream(handle, op, chunk_size) do
    case call(handle, op) do
      {:ok, stream} ->
        {:ok, async_stream(op, stream, chunk_size)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp telemetry(event_name, op, measurements, meta \\ %{})
  defp telemetry(event_name, op, measurements, meta) when is_map(measurements) do
    {name, args} = map_operation(op)
    :telemetry.execute([:gitrekt, :git_agent, event_name], measurements, Map.merge(%{op: name, args: args}, meta))
  end

  defp telemetry(event_name, op, callback, meta) do
    {duration, result} = :timer.tc(callback)
    telemetry(event_name, op, %{duration: duration}, meta)
    result
  end

  defp resolve_odb(odb), do: %GitOdb{__ref__: odb}

  defp resolve_reference({nil, nil, :oid, _oid}), do: nil
  defp resolve_reference({name, nil, :oid, oid}) do
    prefix = Path.dirname(name) <> "/"
    shorthand = Path.basename(name)
    %GitRef{oid: oid, name: shorthand, prefix: prefix, type: resolve_reference_type(prefix)}
  end

  defp resolve_reference({name, shorthand, :oid, oid}) do
    prefix = String.slice(name, 0, String.length(name) - String.length(shorthand))
    %GitRef{oid: oid, name: shorthand, prefix: prefix, type: resolve_reference_type(prefix)}
  end

  defp resolve_reference_type("refs/heads/"), do: :branch
  defp resolve_reference_type("refs/tags/"), do: :tag

  defp resolve_reference_peel!(ref, target, handle) do
    case fetch_reference_target(resolve_reference(ref), target, handle) do
      {:ok, target} ->
        target
      {:error, reason} ->
        raise RuntimeError, message: reason
    end
  end

  defp resolve_peel!(obj, target, handle) do
    case fetch_target(obj, target, handle) do
      {:ok, target} ->
        target
      {:error, reason} ->
        raise RuntimeError, message: reason
    end
  end

  defp resolve_object({blob, :blob, oid}), do: %GitBlob{oid: oid, __ref__: blob}
  defp resolve_object({commit, :commit, oid}), do: %GitCommit{oid: oid, __ref__: commit}
  defp resolve_object({tree, :tree, oid}), do: %GitTree{oid: oid, __ref__: tree}
  defp resolve_object({tag, :tag, oid}) do
    case Git.tag_name(tag) do
      {:ok, name} ->
        %GitTag{oid: oid, name: name, __ref__: tag}
      {:error, _reason} ->
        %GitTag{oid: oid, __ref__: tag}
    end
  end

  defp resolve_commit_parent({oid, commit}), do: %GitCommit{oid: oid, __ref__: commit}

  defp resolve_tree_entry({mode, type, oid, name}), do: %GitTreeEntry{oid: oid, name: name, mode: mode, type: type}

  defp resolve_index(index), do: %GitIndex{__ref__: index}

  defp resolve_diff_delta({{old_file, new_file, count, similarity}, hunks}) do
    %{old_file: resolve_diff_file(old_file), new_file: resolve_diff_file(new_file), count: count, similarity: similarity, hunks: Enum.map(hunks, &resolve_diff_hunk/1)}
  end

  defp resolve_diff_file({oid, path, size, mode}) do
    %{oid: oid, path: path, size: size, mode: mode}
  end

  defp resolve_diff_hunk({{header, old_start, old_lines, new_start, new_lines}, lines}) do
    %{header: header, old_start: old_start, old_lines: old_lines, new_start: new_start, new_lines: new_lines, lines: Enum.map(lines, &resolve_diff_line/1)}
  end

  defp resolve_diff_line({origin, old_line_no, new_line_no, num_lines, content_offset, content}) do
    %{origin: <<origin>>, old_line_no: old_line_no, new_line_no: new_line_no, num_lines: num_lines, content_offset: content_offset, content: content}
  end

  defp resolve_diff_stats({files_changed, insertions, deletions}) do
    %{files_changed: files_changed, insertions: insertions, deletions: deletions}
  end

  defp lookup_object!(oid, handle) do
    case Git.object_lookup(handle, oid) do
      {:ok, obj_type, obj} ->
        resolve_object({obj, obj_type, oid})
      {:error, reason} ->
        raise RuntimeError, message: reason
    end
  end

  defp fetch_reference_target({_name, _shorthand, _type, _target} = ref, target, handle) do
    fetch_reference_target(resolve_reference(ref), target, handle)
  end

  defp fetch_reference_target(ref, :undefined, _handle), do: {:ok, ref}
  defp fetch_reference_target(%GitRef{type: :branch} = ref, _target, _handle), do: {:ok, ref}
  defp fetch_reference_target(%GitRef{type: :tag} = ref, target, handle) do
    case fetch_target(ref, target, handle) do
      {:ok, %GitTag{} = tag} ->
        {:ok, tag}
      {:ok, %GitCommit{oid: oid}} ->
        {:ok, struct(ref, oid: oid)}
      {:error, _reason} ->
        {:ok, ref}
    end
  end

  defp fetch_tree(%GitCommit{__ref__: commit}, _handle) do
    case Git.commit_tree(commit) do
      {:ok, oid, tree} ->
        {:ok, %GitTree{oid: oid, __ref__: tree}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree(%GitRef{name: name, prefix: prefix}, handle) do
    case Git.reference_peel(handle, prefix <> name, :commit) do
      {:ok, obj_type, oid, obj} ->
        fetch_tree(resolve_object({obj, obj_type, oid}), handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree(%GitTag{__ref__: tag}, handle) do
    case Git.tag_peel(tag) do
      {:ok, obj_type, oid, obj} ->
        fetch_tree(resolve_object({obj, obj_type, oid}), handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry(%GitTree{__ref__: tree}, {:oid, oid}, _handle) do
    case Git.tree_byid(tree, oid) do
      {:ok, mode, type, oid, name} ->
        {:ok, resolve_tree_entry({mode, type, oid, name})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry(%GitTree{__ref__: tree}, {:path, path}, _handle) do
    case Git.tree_bypath(tree, path) do
      {:ok, mode, type, oid, name} ->
        {:ok, resolve_tree_entry({mode, type, oid, name})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry(rev, spec, handle) do
    case fetch_tree(rev, handle) do
      {:ok, tree} ->
        fetch_tree_entry(tree, spec, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entry_target(with_target, rev, {:path, path}, handle) do
    case walk_history(rev, handle, pathspec: path) do
      {:ok, stream} ->
        target =
          stream
          |> Stream.map(&resolve_peel!(&1, with_target, handle))
          |> Enum.take(1)
          |> List.first()
        {:ok, target}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entries(%GitTree{__ref__: tree}, _handle) do
    case Git.tree_entries(tree) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &resolve_tree_entry/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entries(rev, handle) do
    case fetch_tree(rev, handle) do
      {:ok, tree} ->
        fetch_tree_entries(tree, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tree_entries(%GitTree{} = tree, path, handle) do
    with {:ok, tree_entry} <- fetch_tree_entry(tree, {:path, path}, handle),
         {:ok, tree} <- fetch_target(tree_entry, :tree, handle), do:
     fetch_tree_entries(tree, handle)
  end

  defp fetch_tree_entries(rev, path, handle) do
    case fetch_tree(rev, handle) do
      {:ok, tree} ->
        fetch_tree_entries(tree, path, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp zip_tree_entries_target(with_target, commit, {root_tree_entry, path_map}, handle) do
    {tree_entries_with_commit, path_map} = zip_tree_entries_target(with_target, commit, path_map, handle)
    {[{root_tree_entry, resolve_peel!(commit, with_target, handle)}|tree_entries_with_commit], path_map}
  end

  defp zip_tree_entries_target(with_target, commit, path_map, handle) when map_size(path_map) > 0 do
    path_map
    |> Enum.filter(fn {path, _entry} -> pathspec_match_commit(commit, [path], handle) end)
    |> Enum.reduce({[], path_map}, fn {path, entry}, {acc, path_map} -> {[{entry, resolve_peel!(commit, with_target, handle)}|acc], Map.delete(path_map, path)} end)
  end

  defp zip_tree_entries_target(_with_target, _commit, path_map, _handle), do: {:halt, path_map}

  defp fetch_diff(%GitTree{__ref__: tree1}, %GitTree{__ref__: tree2}, handle, opts) do
    case Git.diff_tree(handle, tree1, tree2, opts) do
      {:ok, diff} ->
        {:ok, %GitDiff{__ref__: diff}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_diff(obj1, obj2, handle, opts) do
    with {:ok, tree1} <- fetch_tree(obj1, handle),
         {:ok, tree2} <- fetch_tree(obj2, handle), do:
      fetch_diff(tree1, tree2, handle, opts)
  end

  defp fetch_target(%GitRef{oid: oid}, :commit_oid, _handle), do: oid
  defp fetch_target(%GitCommit{oid: oid}, :commit_oid, _handle), do: oid
  defp fetch_target(source, :commit_oid, handle) do
    case fetch_target(source, :commit, handle) do
      {:ok, %GitCommit{oid: oid}} ->
        {:ok, oid}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_target(%GitRef{name: name, prefix: prefix}, target, handle) do
    case Git.reference_peel(handle, prefix <> name, target) do
      {:ok, obj_type, oid, obj} ->
        {:ok, resolve_object({obj, obj_type, oid})}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_target(%GitTag{} = tag, :tag, _handle), do: {:ok, tag}
  defp fetch_target(%GitTag{__ref__: tag}, target, handle) do
    case Git.tag_peel(tag) do
      {:ok, obj_type, oid, obj} ->
        if target == :undefined,
          do: {:ok, resolve_object({obj, obj_type, oid})},
        else: fetch_target(resolve_object({obj, obj_type, oid}), target, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_target(%GitCommit{} = commit, :commit, _handle), do: {:ok, commit}
  defp fetch_target(%GitCommit{} = commit, :tree, handle), do: fetch_tree(commit, handle)

  defp fetch_target(%GitTreeEntry{oid: oid, type: type}, target, handle) do
    case Git.object_lookup(handle, oid) do
      {:ok, ^type, obj} ->
        if target == :undefined,
          do: {:ok, resolve_object({obj, type, oid})},
        else: fetch_target(resolve_object({obj, type, oid}), target, handle)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_target(%GitTree{} = tree, :tree, _handle), do: {:ok, tree}
  defp fetch_target(%GitBlob{} = blob, :blob, _handle), do: {:ok, blob}

  defp fetch_target(source, target, _handle) do
    {:error, "cannot peel #{inspect source} to #{target}"}
  end

  defp fetch_author(%GitCommit{__ref__: commit}) do
    with {:ok, name, email, time, _offset} <- Git.commit_author(commit),
         {:ok, datetime} <- DateTime.from_unix(time), do:
      {:ok, %{name: name, email: email, timestamp: datetime}}
  end

  defp fetch_author(%GitTag{__ref__: tag}) do
    with {:ok, name, email, time, _offset} <- Git.tag_author(tag),
         {:ok, datetime} <- DateTime.from_unix(time), do:
      {:ok, %{name: name, email: email, timestamp: datetime}}
  end

  defp fetch_committer(%GitCommit{__ref__: commit}) do
    with {:ok, name, email, time, _offset} <- Git.commit_committer(commit),
         {:ok, datetime} <- DateTime.from_unix(time), do:
      {:ok, %{name: name, email: email, timestamp: datetime}}
  end

  defp fetch_message(%GitCommit{__ref__: commit}), do: Git.commit_message(commit)
  defp fetch_message(%GitTag{__ref__: tag}), do: Git.tag_message(tag)

  defp walk_history(rev, handle, opts \\ []) do
    {sorting, opts} = Enum.split_with(opts, &(is_atom(&1) && String.starts_with?(to_string(&1), "sort")))
    with {:ok, walk} <- Git.revwalk_new(handle),
          :ok <- Git.revwalk_sorting(walk, sorting),
         {:ok, commit} <- fetch_target(rev, :commit, handle),
          :ok <- Git.revwalk_push(walk, commit.oid),
         {:ok, stream} <- Git.revwalk_stream(walk) do
      stream = Stream.map(stream, &lookup_object!(&1, handle))
      if pathspec = Keyword.get(opts, :pathspec),
        do: {:ok, Stream.filter(stream, &pathspec_match_commit(&1, List.wrap(pathspec), handle))},
      else: {:ok, stream}
    end
  end

  defp pathspec_match_commit(%GitCommit{__ref__: commit}, pathspec, handle) do
    case Git.commit_tree(commit) do
      {:ok, _oid, tree} ->
        pathspec_match_commit_tree(commit, tree, pathspec, handle)
      {:error, _reason} ->
        false
    end
  end

  defp pathspec_match_commit_tree(commit, tree, pathspec, handle) do
    with {:ok, stream} <- Git.commit_parents(commit),
         {_oid, parent} <- Enum.at(stream, 0, :match_tree),
         {:ok, _oid, parent_tree} <- Git.commit_tree(parent),
         {:ok, delta_count} <- pathspec_match_commit_diff(parent_tree, tree, pathspec, handle) do
      delta_count > 0
    else
      :match_tree ->
        case Git.pathspec_match_tree(tree, pathspec) do
          {:ok, match?} -> match?
          {:error, _reason} -> false
        end
      {:error, _reason} ->
        false
    end
  end

  defp pathspec_match_commit_diff(old_tree, new_tree, pathspec, handle) do
    case Git.diff_tree(handle, old_tree, new_tree, pathspec: pathspec) do
      {:ok, diff} -> Git.diff_delta_count(diff)
      {:error, reason} -> {:error, reason}
    end
  end

  defp oid_mask(oids) do
    Enum.map(oids, fn
      {oid, hidden} when is_binary(oid) -> {oid, hidden}
      oid when is_binary(oid) -> {oid, false}
    end)
  end

  defp signature_tuple(%{name: name, email: email, timestamp: datetime}) do
    {name, email, DateTime.to_unix(datetime), datetime.utc_offset}
  end

  defp walk_insert(_walk, []), do: :ok
  defp walk_insert(walk, [{oid, hide}|oids]) do
    case Git.revwalk_push(walk, oid, hide) do
      :ok -> walk_insert(walk, oids)
      {:error, reason} -> {:error, reason}
    end
  end

  defp async_stream(_op, stream, :infinity), do: Enum.to_list(stream)
  defp async_stream(op, stream, chunk_size) do
    agent = self()
    Stream.resource(
      fn -> stream end,
      fn :halt ->
          {:halt, agent}
         stream ->
          telemetry(:stream, op, fn -> GenServer.call(agent, {:stream_next, stream, chunk_size}, @default_config.timeout) end, %{chunk_size: chunk_size})
      end,
      &(&1)
    )
  end

  defp map_operation(op) when is_atom(op), do: {op, []}
  defp map_operation(op) do
    [name|args] = Tuple.to_list(op)
    {name, args}
  end
end
