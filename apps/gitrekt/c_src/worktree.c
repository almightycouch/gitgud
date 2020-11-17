#include "geef.h"
#include "oid.h"
#include "worktree.h"
#include <string.h>
#include <git2.h>

void geef_worktree_free(ErlNifEnv *env, void *cd)
{
	geef_worktree *worktree = (geef_worktree *) cd;
	enif_release_resource(worktree->repo);
	git_worktree_free(worktree->worktree);
}

ERL_NIF_TERM
geef_worktree_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
#if LIBGIT2_VER_MAJOR < 1 && LIBGIT2_VER_MINOR < 27
    ErlNifBinary bin;
	if (geef_string_to_bin(&bin, "libgit2 version >= 0.27.x required") < 0)
		return geef_error(env);
	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
#else
    ErlNifBinary name_bin, path_bin, ref_bin;
	int override;
	geef_repository *repo;
	geef_worktree *worktree;
	ERL_NIF_TERM worktree_term;

	if (!enif_get_resource(env, argv[0], geef_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	worktree = enif_alloc_resource(geef_worktree_type, sizeof(geef_worktree));
	if (!worktree)
		return geef_oom(env);

	if (!enif_inspect_binary(env, argv[1], &name_bin))
		return enif_make_badarg(env);

	if (!geef_terminate_binary(&name_bin))
		return geef_oom(env);

	if (!enif_inspect_binary(env, argv[2], &path_bin))
		return enif_make_badarg(env);

	if (!geef_terminate_binary(&path_bin))
		return geef_oom(env);

	git_worktree_add_options opts = GIT_WORKTREE_ADD_OPTIONS_INIT;
	if (enif_is_identical(argv[3], atoms.undefined)) {
		override = 0;
	} else if (enif_inspect_binary(env, argv[3], &ref_bin)) {
		override = 1;
	} else {
		return enif_make_badarg(env);
	}

	if (override && !geef_terminate_binary(&ref_bin))
	    return atoms.error;

	git_reference *ref;
	if (override) {
		if (git_reference_lookup(&ref, repo->repo, (char *) ref_bin.data) < 0)
			return geef_error(env);
		// TODO
		//opts.ref = ref;
		enif_release_binary(&ref_bin);
	}

	if (git_worktree_add(&worktree->worktree, repo->repo, (char *) name_bin.data, (char *) path_bin.data, &opts) < 0) {
		//enif_release_resource(worktree);
		return geef_error(env);
	}

	enif_release_binary(&name_bin);
	enif_release_binary(&path_bin);

	if (override) {
		git_reference_free(ref);
		enif_release_binary(&ref_bin);
	}

	worktree_term = enif_make_resource(env, worktree);
	enif_release_resource(worktree);
	worktree->repo = repo;
	enif_keep_resource(repo);

	return enif_make_tuple2(env, atoms.ok, worktree_term);
#endif
}

ERL_NIF_TERM
geef_worktree_prune(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
#if LIBGIT2_VER_MAJOR < 1 && LIBGIT2_VER_MINOR < 27
    ErlNifBinary bin;
	if (geef_string_to_bin(&bin, "libgit2 version >= 0.27.x required") < 0)
		return geef_error(env);
	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
#else
	geef_worktree *worktree;

	if (!enif_get_resource(env, argv[0], geef_worktree_type, (void **) &worktree))
		return enif_make_badarg(env);

	git_worktree_prune_options opts = GIT_WORKTREE_PRUNE_OPTIONS_INIT;
	opts.flags |= GIT_WORKTREE_PRUNE_VALID;
	if (git_worktree_prune(worktree->worktree, &opts) < 0) {
		return geef_error(env);
	}

	return atoms.ok;
#endif
}
