/*
 * A stand-in for fx, Claude Code, Codex, Pi, or agy in the end-to-end test.
 * It keeps its conversation's file/directory the way the real program does:
 *
 *   fx      holds FAKE_HOME/.fx/sessions/v2/<id>/lock open
 *   codex   holds FAKE_HOME/.codex/sessions/.../rollout-<time>-<id>.jsonl open;
 *           with --no-rollout it opens nothing, like a new Codex before its first message
 *   claude  writes FAKE_HOME/.claude/projects/<folder>/<id>.jsonl and closes it
 *   pi      writes FAKE_HOME/.pi/agent/sessions/--<slug>--/..._<id>.jsonl and closes it
 *   agy     holds FAKE_HOME/.gemini/antigravity-cli/brain/<id> directory open
 *   droid   writes FAKE_HOME/.factory/sessions/<folder>/<id>.jsonl and closes it;
 *           with --child <id> it then adds that Task subagent's session next to it
 *   cursor-agent  writes FAKE_HOME/.cursor/chats/<md5(cwd)>/<id>/meta.json and
 *           holds store.db open
 *
 * Built by test/e2e.sh with -DAPP="fx" (or claude, codex, pi, agy, droid, cursor-agent) and -DFAKE_HOME.
 */
#include <ctype.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
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

static void make_droid_slug(const char *cwd, char *out, size_t out_sz) {
  size_t len = strlen(cwd);
  while (len > 0 && (cwd[len - 1] == '/' || cwd[len - 1] == '\\')) len--;
  size_t j = 0;
  for (size_t i = 0; i < len && j + 1 < out_sz; i++) {
    char c = cwd[i];
    out[j++] = (c == '/' || c == '\\' || c == ':') ? '-' : c;
  }
  out[j] = 0;
}

static void md5_hex(const char *input, char out[33]) {
  static const uint32_t s[64] = {
    7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
    5, 9,14,20,5, 9,14,20,5, 9,14,20,5, 9,14,20,
    4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
    6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
  };
  static const uint32_t k[64] = {
    0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
    0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
    0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
    0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
    0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
    0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
    0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
    0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
  };
  size_t len = strlen(input);
  size_t padded = ((len + 8) / 64 + 1) * 64;
  uint8_t *msg = calloc(padded, 1);
  if (!msg) { out[0] = 0; return; }
  memcpy(msg, input, len);
  msg[len] = 0x80;
  uint64_t bits = (uint64_t)len * 8;
  for (int i = 0; i < 8; i++) msg[padded - 8 + i] = (uint8_t)((bits >> (8 * i)) & 0xff);
  uint32_t h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476;
  for (size_t off = 0; off < padded; off += 64) {
    uint32_t w[16];
    for (int i = 0; i < 16; i++) {
      w[i] = (uint32_t)msg[off + i * 4]
           | ((uint32_t)msg[off + i * 4 + 1] << 8)
           | ((uint32_t)msg[off + i * 4 + 2] << 16)
           | ((uint32_t)msg[off + i * 4 + 3] << 24);
    }
    uint32_t a = h0, b = h1, c = h2, d = h3;
    for (int i = 0; i < 64; i++) {
      uint32_t f, g;
      if (i < 16) { f = (b & c) | ((~b) & d); g = (uint32_t)i; }
      else if (i < 32) { f = (d & b) | ((~d) & c); g = (uint32_t)((5 * i + 1) % 16); }
      else if (i < 48) { f = b ^ c ^ d; g = (uint32_t)((3 * i + 5) % 16); }
      else { f = c ^ (b | (~d)); g = (uint32_t)((7 * i) % 16); }
      uint32_t tmp = d;
      d = c;
      c = b;
      uint32_t x = a + f + k[i] + w[g];
      b = b + ((x << s[i]) | (x >> (32 - s[i])));
      a = tmp;
    }
    h0 += a; h1 += b; h2 += c; h3 += d;
  }
  free(msg);
  uint32_t digest[4] = { h0, h1, h2, h3 };
  for (int i = 0; i < 4; i++) {
    for (int j = 0; j < 4; j++) {
      snprintf(out + (i * 4 + j) * 2, 3, "%02x", (digest[i] >> (8 * j)) & 0xff);
    }
  }
  out[32] = 0;
}

int main(int argc, char **argv) {
  const char *app = APP;
  char id[128] = "", child[128] = "";
  int no_rollout = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--no-rollout")) {
      no_rollout = 1;
      continue;
    }
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
        i + 1 < argc && argv[i + 1][0] != '-')
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

  if (no_rollout) {
    printf("fake %s without a rollout\n", app);
    fflush(stdout);
    for (;;) pause();
  }

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
  } else if (!strcmp(app, "droid")) {
    char slug[2200];
    make_droid_slug(cwd, slug, sizeof slug);
    snprintf(dir, sizeof dir, "%s/.factory/sessions/%s", FAKE_HOME, slug);
    snprintf(file, sizeof file, "%s/%s.jsonl", dir, id);
    keep_open = 0;
  } else if (!strcmp(app, "cursor-agent")) {
    char hash[33];
    md5_hex(cwd, hash);
    snprintf(dir, sizeof dir, "%s/.cursor/chats/%s/%s", FAKE_HOME, hash, id);
    make_dirs(dir);
    char mfile[4608], mline[4096];
    snprintf(mfile, sizeof mfile, "%s/meta.json", dir);
    snprintf(mline, sizeof mline,
             "{\"hasConversation\":true,\"updatedAtMs\":%lld,\"cwd\":\"%s\"}\n",
             (long long)time(NULL) * 1000LL, cwd);
    write_new(mfile, mline);
    snprintf(file, sizeof file, "%s/store.db", dir);
    keep_open = 1;
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
  } else if (!strcmp(app, "droid")) {
    n = snprintf(line, sizeof line,
                 "{\"type\":\"session_start\",\"version\":2,\"id\":\"%s\",\"cwd\":\"%s\"}\n", id, cwd);
  } else {
    n = snprintf(line, sizeof line,
                 "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%s\",\"cwd\":\"%s\"}}\n", id, cwd);
  }
  if (write(fd, line, (size_t)n) != n) return 1;
  if (!keep_open) close(fd);
  if (!strcmp(app, "droid") && child[0]) {
    /* A Task subagent's session starts later and sits next to its parent's file. */
    sleep(1);
    char cfile[4608], cline[4096];
    snprintf(cfile, sizeof cfile, "%s/%s.jsonl", dir, child);
    snprintf(cline, sizeof cline,
             "{\"type\":\"session_start\",\"version\":2,\"id\":\"%s\",\"callingSessionId\":\"%s\","
             "\"callingToolUseId\":\"call_fake_0\",\"cwd\":\"%s\"}\n",
             child, id, cwd);
    write_new(cfile, cline);
  }
  printf("fake %s on %s\n", app, id);
  fflush(stdout);
  for (;;) pause();
}
