# ClaudeMulti

A launcher and session manager for running [Claude Code](https://claude.com/claude-code)
under several accounts on one machine.

Each account is a separate Claude config directory, selected with
`CLAUDE_CONFIG_DIR`. ClaudeMulti lists the sessions for the current directory from
every account together,
resumes any of them under the account that owns it, and moves a session from one
account to another. A typical reason to move one is that an account has hit its
usage limit partway through a conversation. Every session it starts has
[Remote Control](https://code.claude.com/docs/en/remote-control) on, so you can
pick it up from the Claude app.

```
Claude sessions in ~/brain
════════════════════════════════════════════════════════════════

  1)  marcus1      Sep 21 22:34  ffb6f200... ~/brain  [running, pid 4087528]
      Brain-Dev-Server — why are there 21 emails in my inbox...

  2)  marcus1      Sep 05 20:26  3bf3d3f3... ~/brain
      FOAWA tag and guest registration todos — Add a tag called FOAWA...
```

## Requirements

- Linux (it reads `/proc` and uses GNU `find`, `stat`, `date` and `diff`)
- bash 4.4+
- python3
- `claude` on your `PATH`

## Install

```bash
git clone git@github.com:marcusadolfsson/claudemulti.git ~/claudemulti
ln -s ~/claudemulti/claudemulti.sh ~/.local/bin/claudemulti
```

## Accounts

Every directory directly under `~/.claude-accounts/` is treated as an account:

```
~/.claude-accounts/
    personal/
    work/
```

To add an account, create the directory and log in once with it:

```bash
mkdir -p ~/.claude-accounts/work
CLAUDE_CONFIG_DIR=~/.claude-accounts/work claude     # then /login
```

### Migrating the default install

A normal Claude Code install keeps its data in `~/.claude/` and its settings in
`~/.claude.json`, which sits *outside* that directory. An account under
`CLAUDE_CONFIG_DIR` keeps both inside one directory, so converting the default
install into an account means moving the two together:

```bash
claudemulti -p                         # make sure no Claude is running first

mkdir -p ~/.claude-accounts
mv ~/.claude       ~/.claude-accounts/personal
mv ~/.claude.json  ~/.claude-accounts/personal/.claude.json
```

`personal` can be any name. Your login (`.credentials.json`), sessions,
memory, settings and MCP servers move with it, so `claudemulti -a personal`
picks up where plain `claude` left off, with nothing to log in to again.

Afterwards, plain `claude` starts as a brand-new, logged-out install. Launch
through `claudemulti`, or make the account the default in your shell profile:

```bash
export CLAUDE_CONFIG_DIR=~/.claude-accounts/personal
```

Don't symlink `~/.claude.json` to the moved file. Claude saves that file by
writing a new copy and renaming it into place, which replaces the symlink with
a regular file, and after that the two copies drift apart without warning.

You can also leave the default install where it is and set
`CLAUDEMULTI_INCLUDE_DEFAULT=1`, which lists `~/.claude` as an account named
`default`.

## Usage

Run `claudemulti` with no arguments to get the interactive menu. It lists the
sessions for the current directory, newest first. Pick one by number, or press
Enter for the most recent, then pick an action:

```
Select session [1-3, Enter = 1], n = new session, g = all directories, q = quit: 2

  1) Resume
  2) Transfer to another account and resume there
  3) Back

Select action [1-3, Enter = resume]:
```

At the first prompt, `n` starts a new session in the current directory and `g`
switches between this directory and every directory. `claudemulti -g` starts
with every directory.

What Enter does at each prompt:

| Prompt | Enter |
|---|---|
| Select session | the most recent session |
| Select action | Resume |
| Select account | the account, when only one is on offer |
| Archive the source copy? | **yes** |
| Claude is already running, continue anyway? | **no** |
| Replace the newer destination copy? | **no** |

The last two default to no because saying yes by accident could fork a
conversation or roll it back. A transfer from the menu with two accounts is
therefore Enter, `2`, Enter, Enter.

The same actions are available as flags:

```
claudemulti -a work              fresh session under "work" in the current directory
claudemulti -c                   resume the newest session for this directory, in any account
claudemulti -c -a work           ...only looking in "work"
claudemulti -r                   pick a session to resume from the list
claudemulti -r 3                 resume session 3 from the list (-g -r 3 for the -g list)
claudemulti -r e422              resume by session ID or ID prefix, from any directory
claudemulti -t e422 -a work      copy the session to "work" and resume it there
claudemulti -l                   list this directory's sessions
claudemulti -l -g                list sessions from every directory
claudemulti -l --all             ...including empty ones (see below)
claudemulti -p                   list running Claude instances
claudemulti --accounts           list accounts, with session and running counts
claudemulti -a work -- --model opus    arguments after -- are passed to claude
```

The list shows only sessions whose project is **the current directory**,
the same set Claude's own `/resume` shows. Subdirectories are separate
projects and are not included. `-g` lists every directory. A session ID
given to `-r` or `-t` is found wherever it lives.

The list and `-c` skip **empty sessions**: ones where nothing was typed
and Claude never replied, such as a session opened and closed with `/exit`, or a
Remote Control connection that never got a message. Claude's own `/resume`
list hides these too. Pass `--all` to show them. A session that has replies but
no typed prompt, such as one started by another session, is still listed, as
*(no typed prompt)*.

You can give an account as any prefix that matches only one account, so
`-a wo` works for `work`.

### Environment

| Variable | Default | |
|---|---|---|
| `CLAUDE_PROFILES_BASE` | `~/.claude-accounts` | where accounts live |
| `CLAUDEMULTI_LIMIT` | `30` | sessions shown in the list |
| `CLAUDEMULTI_INCLUDE_DEFAULT` | `0` | set to `1` to include `~/.claude` as an account named `default` |
| `CLAUDEMULTI_REMOTE_CONTROL` | `1` | `0` leaves Remote Control to each account's settings (see below) |

To change a default permanently rather than per run, edit the matching variable
near the top of the script, e.g. `REMOTE_CONTROL`.

## Remote Control

Every session ClaudeMulti starts or resumes has
[Remote Control](https://code.claude.com/docs/en/remote-control) on, so it shows
up in the Claude desktop and mobile apps. It needs a claude.ai login, and on
Team and Enterprise plans an admin must allow it.

How it is turned on depends on whether the session has a name:

| Session | Launched with |
|---|---|
| named, with `/rename` or in the desktop app | `--remote-control "<name>"` |
| unnamed, or a new session | `--settings '{"remoteControlAtStartup":true}'` |

Both apply to that launch only. No account's `settings.json` is changed.

**Why the name is passed explicitly.** A name you set in the app is stored in
two places:

- **In the transcript**, as a `custom-title` entry. This travels with a
  transfer, and it is what the session list shows.
- **On claude.ai**, as the remote session the app displays. That remote session
  belongs to one claude.ai login. Resuming under a different login, which is
  what a transfer does, always creates a new remote session, which would get a
  generated name.

Passing the name from the transcript to `--remote-control` gives the new remote
session your name. Only names you set are passed: Claude's auto-generated
titles are not, so Claude doesn't save one as if you had chosen it. Unnamed
sessions get a new generated name each time they start, with or without a
transfer.

**After a transfer the app shows only new messages.** When Claude resumes a
session whose last remote session belonged to a different claude.ai login, it
does not upload the earlier conversation to the new login. It records
`"type":"history-suppression","cause":"restored_owner_mismatch"` in the
transcript and creates the new remote session with `noHistoryBackfill`. Later
connections carry the same restriction (`"cause":"migration"`). This is a
deliberate guard in Claude Code against moving a conversation from one account
into another, and ClaudeMulti does not work around it. The full history is
still in the transcript and in the terminal session; only the app starts from
the point of the transfer. This happens even when switching back to the
session's original login.

To turn it off for one run, use `CLAUDEMULTI_REMOTE_CONTROL=0 claudemulti`. To
turn it on for plain `claude` too, set `"remoteControlAtStartup": true` in the
account's `settings.json`, or use *Enable Remote Control for all sessions* in
`/config`.

## Running-session detection

Two copies of Claude working on the same conversation will write two different
versions of it. Before any start, resume or transfer, ClaudeMulti checks for
Claude processes already running and warns about:

- **the same session**, in any directory
- **the same project directory**, with a stronger warning when it is also the
  same account

Each running Claude registers itself in `<account>/sessions/<pid>.json`, with
its exact session ID, working directory and tmux pane. ClaudeMulti ignores
stale entries: a crashed process, a PID the system has reused (checked by the
process's start time), or a container sharing the config directory (checked by
the PID namespace). Older Claude versions that don't write this file are still
found with `pgrep`. For those, ClaudeMulti knows the session only if it was
started with `-r <id>`.

## Transferring a session

A session is more than its transcript. A transfer copies everything stored
under the session's ID, which no other session in the destination can be using:

| Path in the account | Contents |
|---|---|
| `projects/<project>/<id>.jsonl` | the transcript |
| `projects/<project>/<id>/` | subagent transcripts, tool results |
| `file-history/<id>/` | file snapshots used by `/rewind` |
| `session-env/<id>/` | environment set by hooks |
| `tasks/<id>/`, `todos/<id>-*.json` | task and todo lists |
| `plans/<slug>.md` | plans the transcript refers to |

Some files are shared with other sessions, so they are treated differently:

- **Project memory** (`projects/<project>/memory/`): files missing from the
  destination are added. Existing ones are never overwritten; any that differ
  are listed so you can merge them by hand.
- **`history.jsonl`** (prompt history): not copied.
- **`.credentials.json`, `.claude.json`, `sessions/`**: never copied. These
  belong to the account, not the session.

### Safety

- The transfer prints a plan first, marking each item `copy`, `same`,
  `replace` or `remove`.
- Everything in the destination that will be replaced or removed is backed up
  first, to
  `<destination>/session-transfer-backups/<id>/<timestamp>/`. The backup keeps
  each file's path within the account, so restoring means copying it back.
- If the destination's copy of the transcript is **newer** than the source's,
  the transfer asks before replacing it, because replacing it would lose the
  newer part of the conversation.
- Each item is copied under a temporary name and then renamed into place, so
  an interrupted transfer never leaves a half-written file. The transcript is
  copied last.
- Transcripts are never merged. One copy replaces the other.

After the transfer you are asked whether to **archive the source copy**
(the default, so pressing Enter archives it),
so that only the destination lists the session and you can't resume the old
copy by mistake. Only the source transcript is moved, to
`<source>/session-transfer-backups/<id>/<timestamp>-archived/`. The session's
other files stay in the source account, so absolute paths inside the transcript
still work.

If you don't archive it, the session exists in both accounts. `-r <id>` will
then ask you to choose one with `-a`.

## Limitations

- `-c` finds sessions by the name Claude gives a project's transcript folder: the
  directory path with every non-alphanumeric character replaced by `-`.
  Claude may name the folder differently for very long paths, and then
  `-c` won't find sessions there. `-r` still will.
- The session file layout is Claude Code's internal format and can change
  between versions.
- After a transfer, the Claude app shows the session's messages from the
  transfer on, not its earlier history (see [Remote Control](#remote-control)).
- Linux only.

## License

MIT — see [LICENSE](LICENSE).
