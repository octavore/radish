//! `rd agent`: printed, not executed. There is no MCP server or structured
//! tool schema here. An agent that can already run a shell command does not
//! need one.

use indoc::indoc;

pub const HELP: &str = indoc! {"
    rd agent: using rd from an AI agent

    Docs managed by rd are not files in this repo's working tree. They live
    in refs/docs/pages, outside `git status`, outside your working
    directory, invisible to Read/Edit/Write/grep. `rd` is the only interface
    to them; there is no on-disk path to open directly.

    Reading:
      rd                    list every doc
      rd list -t            list, newest edited first
      rd cat <path>         print a doc's content
      rd <path>             shorthand for 'rd cat <path>'

    A missing path fails with 'no such page' and suggests close matches.

    Searching (grep-style flags; your own grep can't see docs):
      rd grep <regex>               print path:line:text for every match
      rd grep <regex> design        only docs under design/ (or one doc path)
      rd grep -l <regex>            only the paths of docs that match
      rd grep -F -i 'some text'     literal, case-insensitive
      rd grep -C 2 <regex>          two lines of context around each match
    Also: -S smart case, -w whole word, -v invert, -L paths without a
    match, -c count per doc, -o only the matched text, -N no line numbers,
    -m NUM max matches per doc, -A/-B NUM context after/before. Exit status
    is 0 on a match, 1 on none, 2 on an error.

    Editing, recommended flow:
      1. rd export /tmp/some-dir     dump every doc to a scratch directory
      2. edit file(s) there with your normal file tools
      3. rd edit <path> /tmp/some-dir/<path>

    `rd export` with no directory creates and prints a fresh tmpdir, so step
    1 can just be `dir=$(rd export)`.

    For a single doc, skip export and round-trip through a file directly:
      rd cat design/auth.md > /tmp/auth.md
      # stderr: rd: blob 3f2a... (pass to rd edit --expect ...)
      # edit /tmp/auth.md
      rd edit design/auth.md /tmp/auth.md --expect 3f2a...

    When stdout is not a terminal, `rd cat` prints the doc's blob OID to
    stderr. Pass it to `rd edit --expect` so the write fails if someone else
    changed that doc after you read it. Without --expect, `rd edit`
    overwrites whatever is there. On a rejected write, `rd cat` again,
    reapply your change, and retry.

    `rd edit <path> -` reads from stdin, so a heredoc works with no scratch
    file needed. `rd edit <path>` with no file opens $EDITOR and fails when
    there is no terminal, so always pass '-' or a file:
      rd edit design/auth.md - <<'EOF'
      # Auth
      Sessions are stateless.
      EOF

    Small edits, no round-trip (prefer this for changing a few lines):
      rd replace <path> <old> <new>        replace exact text; it must occur once
      rd replace <path> <old> <new> --all  replace every occurrence
    <old> is matched literally, newlines included, so quote multi-line text
    with $'...' or a single-quoted string spanning lines. With no match or
    more than one, nothing is written; add surrounding text to <old> to make
    it unique. A concurrent edit to the doc makes the write fail rather than
    overwrite it.

    Moving and deleting:
      rd mv <from> <to>     move a doc, or every doc under a folder, in one
                            commit; fails if a destination already exists
      rd rm <path>

    Formatting:
      rd fmt <path>         reformat one doc with rumdl and write it back
      rd fmt                reformat every doc
      rd fmt --check        list docs that need formatting, exit non-zero

    `rd edit` both creates and updates; there is no separate 'new' command.
    Writes that change nothing print 'unchanged <path>' and do not create a
    new commit.
"};
