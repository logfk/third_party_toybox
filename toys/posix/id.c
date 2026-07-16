/* id.c - print real and effective user and group IDs
 *
 * Copyright 2012 Sony Network Entertainment, Inc.
 *
 * by Tim Bird <tim.bird@am.sony.com>
 *
 * See http://opengroup.org/onlinepubs/9699919799/utilities/id.html

USE_ID(NEWTOY(id, ">1"USE_ID_Z("Z")"nGgru[!"USE_ID_Z("Z")"Ggu]", TOYFLAG_USR|TOYFLAG_BIN))
USE_GROUPS(NEWTOY(groups, NULL, TOYFLAG_USR|TOYFLAG_BIN))
USE_LOGNAME(NEWTOY(logname, ">0", TOYFLAG_USR|TOYFLAG_BIN))
USE_WHOAMI(OLDTOY(whoami, logname, TOYFLAG_USR|TOYFLAG_BIN))

config ID
  bool "id"
  default y
  help
    usage: id [-Ggnru] [USER...]

    Print user and group ID.

    -G	Show all group IDs
    -g	Show only the effective group ID
    -n	Print names instead of numeric IDs (to be used with -Ggu)
    -r	Show real ID instead of effective ID
    -u	Show only the effective user ID

config ID_Z
  bool
  default y
  depends on ID && !TOYBOX_LSM_NONE
  help
    usage: id [-Z]

    -Z	Show only security context

config GROUPS
  bool "groups"
  default y
  help
    usage: groups [user]

    Print the groups a user is in.

config LOGNAME
  bool "logname"
  default y
  help
    usage: logname

    Print the current user name.

config WHOAMI
  bool "whoami"
  default y
  help
    usage: whoami

    Print the current user name.
*/

#define FOR_id
#define FORCE_FLAGS
#include "toys.h"

GLOBALS(
  int is_groups;
)

#ifdef TOYBOX_OH_ADAPT
void* dlopen_handle = NULL;
typedef struct passwd* (*oh_getpwuid_)(uid_t uid);
typedef struct passwd* (*oh_getpwnam_)(const char *name);
typedef struct group* (*oh_getgrgid_)(gid_t gid);
typedef int32_t (*oh_getpwuid_r_)(uid_t uid, struct passwd *pw, char *buf, size_t size, struct passwd **res);
oh_getpwuid_ oh_getpwuid_func = NULL;
oh_getpwnam_ oh_getpwnam_func = NULL;
oh_getgrgid_ oh_getgrgid_func = NULL;
oh_getpwuid_r_ oh_getpwuid_r_func = NULL;

static void do_id_deinit()
{
  if (dlopen_handle) {
    dlclose(dlopen_handle);
    dlopen_handle = NULL;
    oh_getpwuid_func = NULL;
    oh_getpwnam_func = NULL;
    oh_getgrgid_func = NULL;
    oh_getpwuid_r_func = NULL;
  }
}

static void do_id_init()
{
  do_id_deinit();
  dlopen_handle = dlopen("libaccount_posix_adapter.z.so", RTLD_LAZY);
  if (!dlopen_handle) return;
  oh_getpwuid_func = (oh_getpwuid_)dlsym(dlopen_handle, "oh_getpwuid");
  oh_getpwnam_func = (oh_getpwnam_)dlsym(dlopen_handle, "oh_getpwnam");
  oh_getgrgid_func = (oh_getgrgid_)dlsym(dlopen_handle, "oh_getgrgid");
  oh_getpwuid_r_func = (oh_getpwuid_r_)dlsym(dlopen_handle, "oh_getpwuid_r");
}

static struct passwd *oh_getpwuid(uid_t uid)
{
  struct passwd *pw = getpwuid(uid);
  if (pw) return pw;
  if (!oh_getpwuid_func) return NULL;
  return oh_getpwuid_func(uid);
}

static struct passwd *oh_xgetpwuid(uid_t uid)
{
  struct passwd *pw = getpwuid(uid);
  if (pw) return pw;
  if (oh_getpwuid_func) pw = oh_getpwuid_func(uid);
  if (!pw) {
    do_id_deinit();
    error_exit("bad uid %ld", (long)uid);
  }
  return pw;
}

static struct passwd *oh_getpwnam(char *name)
{
  struct passwd *pw = getpwnam(name);
  if (pw) return pw;
  if (!oh_getpwnam_func) return NULL;
  const char *copy = strdup(name);
  if (!copy) return NULL;
  pw = oh_getpwnam_func(copy);
  free(copy);
  return pw;
}

static struct group *oh_getgrgid(gid_t gid)
{
  struct group *gr = getgrgid(gid);
  if (gr) return gr;
  if (!oh_getgrgid_func) return NULL;
  return oh_getgrgid_func(gid);
}

static struct group *oh_xgetgrgid(gid_t gid)
{
  struct group *gr = getgrgid(gid);
  if (gr) return gr;
  if (oh_getgrgid_func) gr = oh_getgrgid_func(gid);
  if (!gr) {
    do_id_deinit();
    perror_exit("bad gid %ld", (long)gid);
  }
  return gr;
}

static struct passwd *oh_bufgetpwuid(uid_t uid)
{
  struct passwd *temp = bufgetpwuid(uid);
  if (temp) return temp;
  if (!oh_getpwuid_r_func) return NULL;
  struct pwuidbuf_list {
    struct pwuidbuf_list *next;
    struct passwd pw;
  } *list = 0;
  static struct pwuidbuf_list *pwuidbuf;
  unsigned size = 256;

  for (list = pwuidbuf; list; list = list->next)
    if (list->pw.pw_uid == uid)
      return &(list->pw);

  for (;;) {
    list = xrealloc(list, size *= 2);
    errno = oh_getpwuid_r_func(uid, &list->pw, sizeof(*list)+(char *)list,
        size-sizeof(*list), &temp);
    if (errno != ERANGE) break;
  }

  if (!temp) {
    free(list);
    return NULL;
  }
  list->next = pwuidbuf;
  pwuidbuf = list;

  return &list->pw;
}
#endif

static void showone(char *prefix, char *s, unsigned u, int done)
{
  if (FLAG(n)) printf("%s%s", prefix, s);
  else printf("%s%u", prefix, u);
  if (done) {
    xputc('\n');
#ifdef TOYBOX_OH_ADAPT
    do_id_deinit();
#endif
    xexit();
  }
}

static void showid(char *prefix, unsigned u, char *s)
{
  printf("%s%u(%s)", prefix, u, s);
}

static void do_id(char *username)
{
#ifdef TOYBOX_OH_ADAPT
  do_id_init();
#endif
  struct passwd *pw;
  struct group *grp;
  uid_t uid = getuid(), euid = geteuid();
  gid_t gid = getgid(), egid = getegid();
  gid_t *groups = (gid_t *)toybuf;
  int i = sizeof(toybuf)/sizeof(gid_t), ngroups;

  // check if a username is given
  if (username) {
#ifdef TOYBOX_OH_ADAPT
    pw = oh_getpwnam(username);
#else
    pw = getpwnam(username);
#endif
    if (!pw) {
      uid = atolx_range(username, 0, INT_MAX);
#ifdef TOYBOX_OH_ADAPT
      if ((pw = oh_bufgetpwuid(uid))) username = pw->pw_name;
#else
      if ((pw = bufgetpwuid(uid))) username = pw->pw_name;
#endif
    }
    if (!pw) error_exit("no such user '%s'", username);
    uid = euid = pw->pw_uid;
    gid = egid = pw->pw_gid;
    if (TT.is_groups) printf("%s : ", pw->pw_name);
  }

#ifdef TOYBOX_OH_ADAPT
  pw = oh_xgetpwuid(FLAG(r) ? uid : euid);
#else
  pw = xgetpwuid(FLAG(r) ? uid : euid);
#endif
  if (FLAG(u)) showone("", pw->pw_name, pw->pw_uid, 1);

#ifdef TOYBOX_OH_ADAPT
  grp = oh_xgetgrgid(FLAG(r) ? gid : egid);
#else
  grp = xgetgrgid(FLAG(r) ? gid : egid);
#endif
  if (FLAG(g)) showone("", grp->gr_name, grp->gr_gid, 1);

  ngroups = username ? getgrouplist(username, gid, groups, &i)
    : getgroups(i, groups);
  if (ngroups<0) perror_exit("getgroups");

  if (FLAG(G)) {
    showone("", grp->gr_name, grp->gr_gid, 0);
    for (i = 0; i<ngroups; i++) {
      if (groups[i] != egid) {
#ifdef TOYBOX_OH_ADAPT
        if ((grp=oh_getgrgid(groups[i]))) showone(" ",grp->gr_name,grp->gr_gid,0);
#else
        if ((grp=getgrgid(groups[i]))) showone(" ",grp->gr_name,grp->gr_gid,0);
#endif
        else printf(" %u", groups[i]);
      }
    }
    xputc('\n');
#ifdef TOYBOX_OH_ADAPT
    do_id_deinit();
#endif
    return;
  }

  if (!FLAG(Z)) {
    showid("uid=", pw->pw_uid, pw->pw_name);
    showid(" gid=", grp->gr_gid, grp->gr_name);

    if (!FLAG(r)) {
      if (uid != euid) {
#ifdef TOYBOX_OH_ADAPT
        pw = oh_xgetpwuid(euid);
#else
        pw = xgetpwuid(euid);
#endif
        showid(" euid=", pw->pw_uid, pw->pw_name);
      }
      if (gid != egid) {
#ifdef TOYBOX_OH_ADAPT
        grp = oh_xgetgrgid(egid);
#else
        grp = xgetgrgid(egid);
#endif
        showid(" egid=", grp->gr_gid, grp->gr_name);
      }
    }

    showid(" groups=", gid, grp->gr_name);
    for (i = 0; i<ngroups; i++) {
      if (groups[i] != egid) {
#ifdef TOYBOX_OH_ADAPT
        if ((grp=oh_getgrgid(groups[i]))) showid(",", grp->gr_gid, grp->gr_name);
#else
        if ((grp=getgrgid(groups[i]))) showid(",", grp->gr_gid, grp->gr_name);
#endif
        else printf(",%u", groups[i]);
      }
    }
  }

  if (!CFG_TOYBOX_LSM_NONE) {
    if (lsm_enabled()) {
      char *context = lsm_context();

      printf("%s%s", FLAG(Z) ? "" : " context=", context);
      if (CFG_TOYBOX_FREE) free(context);
    } else if (FLAG(Z)) error_exit("%s disabled", lsm_name());
  }

  xputc('\n');
#ifdef TOYBOX_OH_ADAPT
  do_id_deinit();
#endif
}

void id_main(void)
{
  if (toys.optc) while(*toys.optargs) do_id(*toys.optargs++);
  else do_id(NULL);
}

void groups_main(void)
{
  TT.is_groups = 1;
  toys.optflags = FLAG_G|FLAG_n;
  id_main();
}

void logname_main(void)
{
  toys.optflags = FLAG_u|FLAG_n;
  id_main();
}
