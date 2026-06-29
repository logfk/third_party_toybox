struct watch_data {
  int n;

  pid_t pid, oldpid;
};
extern union global_union {
	struct watch_data watch;
} this;
