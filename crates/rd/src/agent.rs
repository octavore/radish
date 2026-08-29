//! `rd agent` — printed, not executed. There's no MCP server or structured tool
//! schema here on purpose: an agent that can already run a shell command
//! doesn't need one, and this is the whole contract in one place.

use indoc::indoc;

pub const HELP: &str = indoc! {"
    rd agent — using rd from an AI agent

    Docs managed by rd are not files in this repo's working tree. They live
    in refs/docs/pages, outside `git status`, outside your working
    directory, invisible to Read/Edit/Write/grep. `rd` is the only interface
    to them — there is no on-disk path to open directly.

    Reading:
      rd                    list every doc
      rd list -t            list, newest edited first
      rd cat <path>         print a doc's content
      rd <path>             shorthand for 'rd cat <path>'

    Editing — recommended flow:
      1. rd export /tmp/some-dir     dump every doc to a scratch directory
      2. edit file(s) there with your normal file tools
      3. rd edit <path> /tmp/some-dir/<path>

    `rd export` with no directory creates and prints a fresh tmpdir, so step
    1 can just be `dir=$(rd export)`.

    For a single doc, skip export and round-trip through a file directly:
      rd cat design/auth.md > /tmp/auth.md
      # edit /tmp/auth.md
      rd edit design/auth.md /tmp/auth.md

    `rd edit <path>` with no file opens the doc in $EDITOR. `rd edit <path> -`
    reads from stdin, so a heredoc works with no scratch file needed:
      rd edit design/auth.md - <<'EOF'
      # Auth
      Sessions are stateless.
      EOF

    Deleting:
      rd rm <path>

    `rd edit` both creates and updates — there's no separate 'new' command.
    Writes are compare-and-swap against the doc ref, so a concurrent writer
    is rejected rather than silently clobbered; on failure, re-read and retry.
"};
