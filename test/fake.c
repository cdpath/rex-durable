/*
 * A stand-in for fx, Claude Code, Codex, Pi, or agy in the end-to-end test.
 * It keeps its conversation's file/directory the way the real program does:
 *
 *   fx      holds FAKE_HOME/.fx/sessions/v2/<id>/lock open
 *   codex   holds FAKE_HOME/.codex/sessions/.../rollout-<time>-<id>.jsonl open
 *   claude  writes FAKE_HOME/.claude/projects/<folder>/<id>.jsonl and closes it
 *   pi      writes FAKE_HOME/.pi/agent/sessions/--<slug>--/..._<id>.jsonl and closes it
 *   agy     holds FAKE_HOME/.gemini/antigravity-cli/brain/<id> directory open
 *
 * Built by test/e2e.sh with -DAPP="fx" (or claude, codex, pi, agy) and -DFAKE_HOME.
 */
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void make_dirs(const char *path) {
  char buf[4096];
  snprintf(buf, sizeof buf, "%s", path);
  for (char *p = buf + 1; *p; p++) {
    if (*p == '/') {
      *p = 0;
      mkdir(buf, 0755);
      *p = '/';
    }
  }
  mkdir(buf, 0755);
}

static void write_new(const char *path, const char *line) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
  if (fd < 0) return;
  if (write(fd, line, strlen(line)) < 0) {
  }
  close(fd);
}

static void make_pi_slug(const char *cwd, char *out, size_t out_sz) {
  const char *start = cwd;
  while (*start == '/' || *start == '\\') start++;
  size_t len = strlen(start);
  while (len > 0 && (start[len - 1] == '/' || start[len - 1] == '\\')) len--;
  char mid[2048];
  size_t j = 0;
  for (size_t i = 0; i < len && j + 1 < sizeof mid; i++) {
    char c = start[i];
    mid[j++] = (c == '/' || c == '\\' || c == ':') ? '-' : c;
  }
  mid[j] = 0;
  snprintf(out, out_sz, "--%s--", mid);
}

int main(int argc, char **argv) {
  const char *app = APP;
  char id[128] = "", child[128] = "";
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--child") && i + 1 < argc) {
      snprintf(child, sizeof child, "%s", argv[++i]);
      continue;
    }
    if (!strcmp(argv[i], "--help")) {
      printf("usage: %s [-r, --resume [last|<id>]]\n", app);
      return 0;
    }
    if ((!strcmp(argv[i], "--resume") || !strcmp(argv[i], "-r") || !strcmp(argv[i], "resume") ||
         !strcmp(argv[i], "--session") || !strcmp(argv[i], "--session-id") ||
         !strcmp(argv[i], "--conversation") || !strcmp(argv[i], "--switch")) &&
        i + 1 < argc)
      snprintf(id, sizeof id, "%s", argv[++i]);
  }
  if (!id[0]) {
    if (!strcmp(app, "fx"))
      snprintf(id, sizeof id, "new%d", (int)getpid());
    else
      snprintf(id, sizeof id, "00000000-0000-4000-8000-%012d", (int)getpid());
  }

  char cwd[2048], dir[4096], file[4608];
  if (!getcwd(cwd, sizeof cwd)) return 1;

  if (!strcmp(app, "agy")) {
    if (child[0]) {
      char sdir[4096];
      snprintf(sdir, sizeof sdir, "%s/.gemini/antigravity-cli/brain/%s", FAKE_HOME, child);
      make_dirs(sdir);
      if (open(sdir, O_RDONLY) < 0) return 1;
      char ldir[4096], lfile[4608], line[512];
      snprintf(ldir, sizeof ldir, "%s/.gemini/antigravity-cli/brain/%s/.system_generated/logs",
               FAKE_HOME, id);
      make_dirs(ldir);
      snprintf(lfile, sizeof lfile, "%s/transcript.jsonl", ldir);
      snprintf(line, sizeof line,
               "{\"tool_calls\":[{\"name\":\"invoke_subagent\"}],\"content\":\"%s\"}\n", child);
      write_new(lfile, line);
    }
    snprintf(dir, sizeof dir, "%s/.gemini/antigravity-cli/brain/%s", FAKE_HOME, id);
    make_dirs(dir);
    if (open(dir, O_RDONLY) < 0) {
      perror(dir);
      return 1;
    }
    printf("fake %s on %s\n", app, id);
    fflush(stdout);
    for (;;) pause();
  }

  int keep_open = 1;
  if (!strcmp(app, "fx")) {
    if (child[0]) {
      char cdir[4096], cfile[4608], line[512];
      snprintf(cdir, sizeof cdir, "%s/.fx/sessions/v2/%s", FAKE_HOME, child);
      make_dirs(cdir);
      snprintf(cfile, sizeof cfile, "%s/log.jsonl", cdir);
      snprintf(line, sizeof line,
               "{\"kind\":\"session_created\",\"id\":\"%s\",\"role\":\"child\",\"parent\":\"%s\"}\n",
               child, id);
      write_new(cfile, line);
      snprintf(cfile, sizeof cfile, "%s/lock", cdir);
      if (open(cfile, O_WRONLY | O_CREAT, 0644) < 0) return 1;
    }
    snprintf(dir, sizeof dir, "%s/.fx/sessions/v2/%s", FAKE_HOME, id);
    snprintf(file, sizeof file, "%s/lock", dir);
  } else if (!strcmp(app, "codex")) {
    snprintf(dir, sizeof dir, "%s/.codex/sessions/2026/11/13", FAKE_HOME);
    snprintf(file, sizeof file, "%s/rollout-2026-11-13T10-00-00-%s.jsonl", dir, id);
  } else if (!strcmp(app, "pi")) {
    char slug[2200];
    make_pi_slug(cwd, slug, sizeof slug);
    snprintf(dir, sizeof dir, "%s/.pi/agent/sessions/%s", FAKE_HOME, slug);
    snprintf(file, sizeof file, "%s/2026-11-18T10-00-00-000Z_%s.jsonl", dir, id);
    keep_open = 0;
  } else {
    char slug[2048];
    snprintf(slug, sizeof slug, "%s", cwd);
    for (char *p = slug; *p; p++)
      if (!isalnum((unsigned char)*p)) *p = '-';
    snprintf(dir, sizeof dir, "%s/.claude/projects/%s", FAKE_HOME, slug);
    snprintf(file, sizeof file, "%s/%s.jsonl", dir, id);
    keep_open = 0;
  }
  make_dirs(dir);
  int fd = open(file, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) {
    perror(file);
    return 1;
  }
  char line[4096];
  int n;
  if (!strcmp(app, "pi")) {
    n = snprintf(line, sizeof line,
                 "{\"type\":\"session\",\"version\":3,\"id\":\"%s\",\"cwd\":\"%s\"}\n", id, cwd);
  } else {
    n = snprintf(line, sizeof line,
                 "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%s\",\"cwd\":\"%s\"}}\n", id, cwd);
  }
  if (write(fd, line, (size_t)n) != n) return 1;
  if (!keep_open) close(fd);
  printf("fake %s on %s\n", app, id);
  fflush(stdout);
  for (;;) pause();
}
