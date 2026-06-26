struct dmesg_data {
  long n, s;

  int use_color;
  time_t tea;
};
extern union global_union {
	struct dmesg_data dmesg;
} this;
