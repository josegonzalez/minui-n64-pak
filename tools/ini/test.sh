#!/bin/sh
# Unit tests for the ini CLI tool.
# Runs against a native-compiled binary (no cross-compilation needed).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INI="$SCRIPT_DIR/build/ini"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$label" "$expected" "$actual"
    fi
}

assert_exit() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected exit %s, got %s\n" "$label" "$expected" "$actual"
    fi
}

# ── Test fixtures ──────────────────────────────────────────────────────────

cat > "$TMPDIR/basic.ini" << 'EOF'
[Core]
key1 = value1
key2 = 42

[Video]
resolution = 1024x768
anisotropy = 2
EOF

cat > "$TMPDIR/quoted.ini" << 'EOF'
[UI-Console]
VideoPlugin = "mupen64plus-video-GLideN64.so"
AudioPlugin = "mupen64plus-audio-sdl.so"
EOF

cat > "$TMPDIR/sectionless.txt" << 'EOF'
font=1
screen=2
lang=en
EOF

cat > "$TMPDIR/comments.ini" << 'EOF'
# This is a comment
[Section]
# Another comment
key = value
; semicolon comment
key2 = value2
EOF

cat > "$TMPDIR/duplicate_sections.ini" << 'EOF'
[Core]
key1 = first

[Other]
x = 1

[Core]
key1 = second
key2 = added
EOF

cat > "$TMPDIR/whitespace.ini" << 'EOF'
[Section]
  key_with_spaces  =  value_with_spaces
normal = clean
EOF

cat > "$TMPDIR/empty_value.ini" << 'EOF'
[Section]
empty =
notempty = hello
EOF

# ── get: basic reads ───────────────────────────────────────────────────────

result=$("$INI" get "$TMPDIR/basic.ini" "Core" "key1")
assert_eq "get basic string" "value1" "$result"

result=$("$INI" get "$TMPDIR/basic.ini" "Core" "key2")
assert_eq "get basic int" "42" "$result"

result=$("$INI" get "$TMPDIR/basic.ini" "Video" "resolution")
assert_eq "get different section" "1024x768" "$result"

result=$("$INI" get "$TMPDIR/basic.ini" "Video" "anisotropy")
assert_eq "get anisotropy" "2" "$result"

# ── get: quote stripping ──────────────────────────────────────────────────

result=$("$INI" get "$TMPDIR/quoted.ini" "UI-Console" "VideoPlugin")
assert_eq "get strips quotes" "mupen64plus-video-GLideN64.so" "$result"

result=$("$INI" get "$TMPDIR/quoted.ini" "UI-Console" "AudioPlugin")
assert_eq "get strips quotes 2" "mupen64plus-audio-sdl.so" "$result"

# ── get: sectionless keys (empty section) ─────────────────────────────────

result=$("$INI" get "$TMPDIR/sectionless.txt" "" "font")
assert_eq "get sectionless font" "1" "$result"

result=$("$INI" get "$TMPDIR/sectionless.txt" "" "screen")
assert_eq "get sectionless screen" "2" "$result"

result=$("$INI" get "$TMPDIR/sectionless.txt" "" "lang")
assert_eq "get sectionless lang" "en" "$result"

# ── get: missing key returns exit 1 ──────────────────────────────────────

"$INI" get "$TMPDIR/basic.ini" "Core" "nonexistent" > /dev/null 2>&1 || rc=$?
assert_exit "get missing key" "1" "${rc:-0}"

# ── get: missing section returns exit 1 ──────────────────────────────────

rc=0
"$INI" get "$TMPDIR/basic.ini" "NoSection" "key1" > /dev/null 2>&1 || rc=$?
assert_exit "get missing section" "1" "$rc"

# ── get: missing file returns exit 2 ─────────────────────────────────────

rc=0
"$INI" get "$TMPDIR/nonexistent.ini" "Core" "key1" > /dev/null 2>&1 || rc=$?
assert_exit "get missing file" "2" "$rc"

# ── get: comments are skipped ────────────────────────────────────────────

result=$("$INI" get "$TMPDIR/comments.ini" "Section" "key")
assert_eq "get with comments" "value" "$result"

result=$("$INI" get "$TMPDIR/comments.ini" "Section" "key2")
assert_eq "get after semicolon comment" "value2" "$result"

# ── get: duplicate sections (last value wins) ────────────────────────────

result=$("$INI" get "$TMPDIR/duplicate_sections.ini" "Core" "key1")
assert_eq "get duplicate section last wins" "second" "$result"

result=$("$INI" get "$TMPDIR/duplicate_sections.ini" "Core" "key2")
assert_eq "get key from second section block" "added" "$result"

# ── get: whitespace handling ─────────────────────────────────────────────

result=$("$INI" get "$TMPDIR/whitespace.ini" "Section" "key_with_spaces")
assert_eq "get trims whitespace" "value_with_spaces" "$result"

# ── get: empty value ─────────────────────────────────────────────────────

result=$("$INI" get "$TMPDIR/empty_value.ini" "Section" "empty")
assert_eq "get empty value" "" "$result"

result=$("$INI" get "$TMPDIR/empty_value.ini" "Section" "notempty")
assert_eq "get non-empty after empty" "hello" "$result"

# ── merge: basic key replacement ─────────────────────────────────────────

cp "$TMPDIR/basic.ini" "$TMPDIR/merge_base.ini"
cat > "$TMPDIR/merge_overlay.ini" << 'EOF'
[Core]
key2 = 99

[Video]
anisotropy = 4
EOF

"$INI" merge "$TMPDIR/merge_base.ini" "$TMPDIR/merge_overlay.ini"
result=$("$INI" get "$TMPDIR/merge_base.ini" "Core" "key2")
assert_eq "merge replaces key" "99" "$result"

result=$("$INI" get "$TMPDIR/merge_base.ini" "Core" "key1")
assert_eq "merge preserves unmatched key" "value1" "$result"

result=$("$INI" get "$TMPDIR/merge_base.ini" "Video" "anisotropy")
assert_eq "merge replaces in other section" "4" "$result"

result=$("$INI" get "$TMPDIR/merge_base.ini" "Video" "resolution")
assert_eq "merge preserves unmatched in other section" "1024x768" "$result"

# ── merge: add new keys to existing section ──────────────────────────────

cp "$TMPDIR/basic.ini" "$TMPDIR/merge_add.ini"
cat > "$TMPDIR/merge_add_overlay.ini" << 'EOF'
[Core]
new_key = new_value
EOF

"$INI" merge "$TMPDIR/merge_add.ini" "$TMPDIR/merge_add_overlay.ini"
result=$("$INI" get "$TMPDIR/merge_add.ini" "Core" "new_key")
assert_eq "merge adds new key" "new_value" "$result"

result=$("$INI" get "$TMPDIR/merge_add.ini" "Core" "key1")
assert_eq "merge preserves existing after add" "value1" "$result"

# ── merge: add new section ───────────────────────────────────────────────

cp "$TMPDIR/basic.ini" "$TMPDIR/merge_newsec.ini"
cat > "$TMPDIR/merge_newsec_overlay.ini" << 'EOF'
[NewSection]
brand = new
EOF

"$INI" merge "$TMPDIR/merge_newsec.ini" "$TMPDIR/merge_newsec_overlay.ini"
result=$("$INI" get "$TMPDIR/merge_newsec.ini" "NewSection" "brand")
assert_eq "merge adds new section" "new" "$result"

result=$("$INI" get "$TMPDIR/merge_newsec.ini" "Core" "key1")
assert_eq "merge preserves original after new section" "value1" "$result"

# ── merge: preserves comments ────────────────────────────────────────────

cp "$TMPDIR/comments.ini" "$TMPDIR/merge_comments.ini"
cat > "$TMPDIR/merge_comments_overlay.ini" << 'EOF'
[Section]
key = updated
EOF

"$INI" merge "$TMPDIR/merge_comments.ini" "$TMPDIR/merge_comments_overlay.ini"
result=$("$INI" get "$TMPDIR/merge_comments.ini" "Section" "key")
assert_eq "merge updates value with comments" "updated" "$result"

# Verify comments are preserved in the file
comment_count=$(grep -c '^#' "$TMPDIR/merge_comments.ini")
assert_eq "merge preserves comment lines" "2" "$comment_count"

# ── merge: empty overlay is no-op ────────────────────────────────────────

cp "$TMPDIR/basic.ini" "$TMPDIR/merge_empty.ini"
cat > "$TMPDIR/merge_empty_overlay.ini" << 'EOF'
EOF

"$INI" merge "$TMPDIR/merge_empty.ini" "$TMPDIR/merge_empty_overlay.ini"
result=$("$INI" get "$TMPDIR/merge_empty.ini" "Core" "key1")
assert_eq "merge empty overlay preserves base" "value1" "$result"

# ── merge: quoted values ─────────────────────────────────────────────────

cp "$TMPDIR/quoted.ini" "$TMPDIR/merge_quoted.ini"
cat > "$TMPDIR/merge_quoted_overlay.ini" << 'EOF'
[UI-Console]
VideoPlugin = "mupen64plus-video-rice.so"
EOF

"$INI" merge "$TMPDIR/merge_quoted.ini" "$TMPDIR/merge_quoted_overlay.ini"
result=$("$INI" get "$TMPDIR/merge_quoted.ini" "UI-Console" "VideoPlugin")
assert_eq "merge quoted value" "mupen64plus-video-rice.so" "$result"

# ── merge: missing overlay file returns error ────────────────────────────

rc=0
"$INI" merge "$TMPDIR/basic.ini" "$TMPDIR/nonexistent_overlay.ini" 2>/dev/null || rc=$?
assert_exit "merge missing overlay" "1" "$rc"

# ── usage: no args returns exit 2 ────────────────────────────────────────

rc=0
"$INI" 2>/dev/null || rc=$?
assert_exit "no args exit code" "2" "$rc"

rc=0
"$INI" get 2>/dev/null || rc=$?
assert_exit "get too few args" "2" "$rc"

# ── Report ───────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
