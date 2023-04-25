// Copyright 2023 Mitchell Kember. Subject to the MIT License.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct Post {
  int64_t date;
  char *json;
};

struct DateString {
  uint8_t y[4];
  uint8_t hyphen1;
  uint8_t m[2];
  uint8_t hyphen2;
  uint8_t d[2];
};

enum { MAX_POSTS = 100, METADATA_MAX_SIZE = 256 };

static struct Post posts[MAX_POSTS];
static char buffer[MAX_POSTS * METADATA_MAX_SIZE];

static int cmp_posts(const void *lhs, const void *rhs) {
  int64_t lhs_date = ((const struct Post *)lhs)->date;
  int64_t rhs_date = ((const struct Post *)rhs)->date;
  int64_t d = rhs_date - rhs_date;
  return (d > 0) - (d < 0);
}

int main(void) {
  const char posts_dir[] = "posts";
  const char metadata_separator[] = "---\n";
  const int date_line_len = strlen("date: YYYY-MM-DD\n");

  DIR *d = opendir(posts_dir);
  if (!d) {
    perror(posts_dir);
    return 1;
  }
  chdir(posts_dir);
  struct dirent *ent;
  char *buf = buffer;
  int nposts = 0;
  while ((ent = readdir(d)) != NULL) {
    const char *name = ent->d_name;
    if (name[0] == '.') {
      continue;
    }
    struct Post post;
    post.json = buf;
    buf += sprintf(buf, "{\"path\": \"%s\"", name);
    FILE *f = fopen(name, "r");
    if (!f) {
      perror(name);
      return 1;
    }
    char *line = NULL;
    size_t cap;
    int len;
    getline(&line, &cap, f);
    while ((len = getline(&line, &cap, f)) != -1 &&
           strcmp(line, metadata_separator) != 0) {
      const char *colon = strchr(line, ':');
      if (!colon) {
        fprintf(stderr, "%s: missing colon in line:\n\t%s", name, line);
        return 1;
      }
      int key_len = colon - line;
      buf += sprintf(buf, ", \"%.*s\": \"%.*s\"", key_len, line,
                     len - key_len - 3, colon + 2);
      if (strncmp(line, "date", colon - line) == 0) {
        if (len != date_line_len) {
          fprintf(stderr, "%s: malformed date line:\n\t%s", name, line);
          return 1;
        }
        struct DateString s = *(struct DateString *)(colon + 2);
        uint64_t date = (uint64_t)s.y[0] << 56 | (uint64_t)s.y[1] << 48 |
                        (uint64_t)s.y[2] << 40 | (uint64_t)s.y[3] << 32 |
                        (uint64_t)s.m[0] << 24 | (uint64_t)s.m[1] << 16 |
                        (uint64_t)s.d[0] << 8 | (uint64_t)s.d[1];
        post.date = (int64_t)date;
      }
    }
    fclose(f);
    *buf++ = '}';
    *buf++ = '\0';
    posts[nposts++] = post;
    if (nposts > MAX_POSTS) {
      fprintf(stderr, "too many posts (%d)\n", nposts);
      return 1;
    }
  }
  qsort(posts, nposts, sizeof(struct Post), cmp_posts);
  printf("[\n");
  for (int i = 0; i < nposts; i++) {
    puts(posts[i].json);
  }
  printf("]\n");
  closedir(d);
}
