"""Find the `dart pub publish` invocations in a shell command, for the guards.

Shared by guard-publish.py, guard-release-docs.py and guard-release-registry.py,
which import it from their own directory and block a publish-looking command
when the import fails.

The guards used a regular expression per hook. That failed in both
directions: a prefix it could not read (`FOO=$(a $(b) c)`, `fvm`, `sudo`,
`bash -c`) meant "not a publish", and its nested quantifiers backtracked
exponentially on `env a=b a=b …`, so a hook ran into its timeout, which also
lets the command through. This module reads the command once, left to right,
the way a shell splits it:

  * words, with single and double quotes, backslashes, `$(…)` (nested),
    `$((…))`, backticks and `#` comments;
  * commands, split at `;`, `&&`, `||`, `|`, `&`, newlines and `( … )`
    subshells; a `cd` inside a subshell that closes before the publish does
    not move it;
  * redirections, whose targets are not words of the command;
  * here-documents, whose bodies are data unless a shell reads them.

Each simple command has its leading `NAME=value` assignments stripped, then
the wrappers that run the rest (`env`, `timeout`, `nice`, `nohup`, `time`,
`command`, `exec`, `stdbuf`, `sudo`, `fvm`). `bash -c`, `sh -c`, `zsh -c` and
`eval` are read again as commands, as are command substitutions.

Fail closed: `PublishUnclear` is raised when the text holds `pub publish` and
the reading cannot say where every publish is — a quote that does not close,
a shell reading its commands from stdin, or the words `pub publish` in a
position this module does not know (`xargs dart pub publish`). The guards
block on it. Plain text is not a publish: an argument of another command
(`grep "dart pub publish"`, a commit message) or a here-document body that
no shell reads.

Out of scope: deliberate disguise. The guards catch mistakes in a release
run, not an attacker: a publish assembled from pieces at run time (`eval $X`
of a quote-split string, `env -S` with a variable inside the word, `printf
… | sh`, base64 into a shell) is not read.
"""
import os
import re

# `pub`, or `packages`, flutter's alias of it (`flutter packages publish`).
_PUB_WORD = re.compile(r"\b(?:pub|packages)\b")
_SUBCOMMANDS = ("publish", "lish", "lush")  # pub's aliases for publish
_SUB_WORD = re.compile(r"\b(?:publish|lish|lush)\b")
_BRACES = re.compile(r"\{[^{}]*,[^{}]*\}")
_ANSI_C = re.compile(r"\$'((?:[^'\\]|\\.)*)'", re.S)
_ESCAPES = {
    "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n",
    "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?",
}


def _mentions_publish(text):
    """`pub` and one of its publish subcommands, both visible in [text]."""
    return bool(_PUB_WORD.search(text) and _SUB_WORD.search(text))


def _decode_ansi_c(body):
    """The text bash makes of `$'[body]'`."""
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c != "\\" or i + 1 >= len(body):
            out.append(c)
            i += 1
            continue
        e = body[i + 1]
        i += 2
        if e in _ESCAPES:
            out.append(_ESCAPES[e])
        elif e in "xuU":
            width = {"x": 2, "u": 4, "U": 8}[e]
            m = re.match(rf"[0-9A-Fa-f]{{1,{width}}}", body[i:])
            # Past U+10FFFF there is no character (chr() would raise): kept
            # as written.
            if m and int(m.group(0), 16) <= 0x10FFFF:
                out.append(chr(int(m.group(0), 16)))
                i += len(m.group(0))
            else:
                out.append("\\" + e)
        elif e in "01234567":
            m = re.match(r"[0-7]{0,2}", body[i:])
            out.append(chr(int(e + m.group(0), 8) & 0xFF))
            i += len(m.group(0))
        elif e == "c" and i < len(body):
            out.append(chr(ord(body[i]) & 0x1F))
            i += 1
        else:
            out.append("\\" + e)
    return "".join(out)


def mentions_publish(text):
    """Whether [text] may hold a publish, read loosely: `$'…'` decoded,
    quotes and backslashes dropped, then `pub` (or `packages`) and a publish
    word anywhere. Linear. For the paths that cannot read the command: when
    in doubt, a publish."""
    text = _ANSI_C.sub(lambda m: _decode_ansi_c(m.group(1)), text)
    return _mentions_publish(re.sub(r"[\"'\\]", "", text))
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"}
_ENDS = {"fi", "done", "esac", "}"}


class PublishUnclear(Exception):
    """The command holds `pub publish`, but where it runs cannot be read."""


class Publish:
    """One `dart|flutter pub publish` the command runs."""

    def __init__(self, env, args, directory):
        # The assignments in front of this publish (its own prefix and its
        # wrappers', and those of a `bash -c` around it).
        self.env = env
        self.args = args
        # Where it runs; None when a `cd` or `-C` target is not in the text.
        self.directory = directory

    @property
    def dry_run(self):
        return "--dry-run" in self.args

    def skip_reason(self, var):
        """The non-blank value of [var] in this publish's own prefix, or None."""
        value = self.env.get(var)
        if value is None:
            return None
        return value.strip() or None

    def __repr__(self):
        return f"Publish({self.directory!r}, {self.args!r}, {self.env!r})"


class _Word:
    __slots__ = ("text", "bare", "expands", "assign_name", "subs")

    def __init__(self):
        self.text = ""
        self.bare = ""  # its unquoted characters, where braces expand
        self.expands = False  # an unquoted or double-quoted `$`/backtick
        self.assign_name = None  # NAME of an unquoted `NAME=` at the start
        self.subs = []  # command substitutions inside it, as text


class _Command:
    __slots__ = ("words", "heredocs", "before", "after")

    def __init__(self, before=None):
        self.words = []
        self.heredocs = []  # bodies, in order
        # The operators around it: None (the start or end), ";", "\n",
        # "&&", "||", "|", "|&", "&", "(" or ")".
        self.before = before
        self.after = None


class _Scanner:
    """Splits shell text into commands and subshell markers, left to right.

    Every character is looked at a bounded number of times; nesting
    (`$(…)`, backticks, `bash -c`) recurses on the inner text once.
    """

    def __init__(self, text):
        self.s = text
        self.i = 0

    def fail(self, why):
        raise _ScanError(why)

    def events(self, stop=None):
        """('cmd', _Command), 'open', 'close' until [stop] or the end."""
        s = self.s
        out = []
        last = "(" if stop == ")" else None
        cmd = _Command(last)
        word = None
        pending = []  # (delimiter, strip_tabs, command) heredocs to read
        skip_target = False  # the next word is a redirection target

        def end_word():
            nonlocal word, skip_target
            if word is None:
                return
            if skip_target:
                skip_target = False
            else:
                cmd.words.append(word)
            word = None

        def end_command(sep):
            nonlocal cmd, last
            end_word()
            if cmd.words or cmd.heredocs:
                cmd.after = sep
                out.append(("cmd", cmd))
            last = sep
            cmd = _Command(last)

        while self.i < len(s):
            c = s[self.i]
            if stop is not None and c == stop and stop == ")":
                end_command(")")
                self.i += 1
                return out
            if c in " \t":
                end_word()
                self.i += 1
            elif c == "\n":
                end_word()
                self.i += 1
                if pending:
                    for delim, strip, owner in pending:
                        owner.heredocs.append(self.heredoc(delim, strip))
                    pending = []
                end_command("\n")
            elif c == "#" and word is None:
                while self.i < len(s) and s[self.i] != "\n":
                    self.i += 1
            elif c in ";&|":
                if c == "&" and s.startswith("&>", self.i):
                    end_word()
                    self.i += 2
                    if self.i < len(s) and s[self.i] == ">":
                        self.i += 1
                    skip_target = True
                    continue
                j = self.i + 1
                while j < len(s) and s[j] in ";&|":
                    j += 1
                end_command(s[self.i : j])
                self.i = j
            elif c == "(":
                end_command("(")
                out.append("open")
                self.i += 1
                out.extend(self.events(stop=")"))
                out.append("close")
                last = ")"
                cmd = _Command(last)
            elif c == ")":
                if stop == ")":
                    end_command(")")
                    self.i += 1
                    return out
                end_command(")")
                out.append("close")
                self.i += 1
            elif c in "<>":
                if word is not None and word.text.isdigit() and not word.expands:
                    word = None  # the fd number of `2>`
                end_word()
                if s.startswith("<<<", self.i):
                    self.i += 3
                    skip_target = True
                elif s.startswith("<<", self.i):
                    self.i += 2
                    strip = False
                    if self.i < len(s) and s[self.i] == "-":
                        strip = True
                        self.i += 1
                    while self.i < len(s) and s[self.i] in " \t":
                        self.i += 1
                    delim = self.read_word(heredoc_delimiter=True)
                    if not delim.text:
                        self.fail("a here-document without a delimiter")
                    pending.append((delim.text, strip, cmd))
                else:
                    self.i += 1
                    while self.i < len(s) and s[self.i] in "<>&|":
                        self.i += 1
                    if self.i < len(s) and s[self.i] == "-":
                        self.i += 1  # >&-
                        continue
                    if self.i < len(s) and s[self.i].isdigit():
                        if s[self.i - 1] == "&":
                            while self.i < len(s) and s[self.i].isdigit():
                                self.i += 1
                            continue
                    skip_target = True
            else:
                if word is None:
                    word = self.read_word()
                    if (
                        stop == ")"
                        and self.i < len(s)
                        and s[self.i] == ")"
                    ):
                        pass
                else:
                    more = self.read_word()
                    word.text += more.text
                    word.expands |= more.expands
                    word.subs += more.subs
        if stop == ")":
            self.fail("a `(` or `$(` that does not close")
        if pending:
            # A here-document that never ends runs to the end of the text.
            for _, _, owner in pending:
                owner.heredocs.append("")
        end_command(None)
        return out

    def heredoc(self, delim, strip):
        s = self.s
        lines = []
        while self.i < len(s):
            j = s.find("\n", self.i)
            if j < 0:
                j = len(s)
            line = s[self.i : j]
            self.i = j + 1 if j < len(s) else j
            if (line.lstrip("\t") if strip else line) == delim:
                return "\n".join(lines)
            lines.append(line)
        return "\n".join(lines)

    def read_word(self, heredoc_delimiter=False):
        """One word from here, up to whitespace or an operator."""
        s = self.s
        w = _Word()
        start = self.i
        assign_checked = False
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\n;&|<>" or c in "()" and not (c == "(" and False):
                if c == "(" or c == ")":
                    break
                break
            if not assign_checked and c == "=" and _NAME.match(s[start : self.i]):
                w.assign_name = s[start : self.i]
                assign_checked = True
                w.text += c
                self.i += 1
                continue
            if c in "'\"$`\\":
                assign_checked = True if c != "$" else assign_checked
            if c == "'":
                j = s.find("'", self.i + 1)
                if j < 0:
                    self.fail("a ' that does not close")
                w.text += s[self.i + 1 : j]
                self.i = j + 1
            elif c == '"':
                self.i += 1
                self.double_quoted(w)
            elif c == "\\":
                if self.i + 1 < len(s):
                    if s[self.i + 1] != "\n":
                        w.text += s[self.i + 1]
                    self.i += 2
                else:
                    self.i += 1
            elif c == "$" and not heredoc_delimiter:
                self.dollar(w)
            elif c == "`" and not heredoc_delimiter:
                self.backtick(w)
            else:
                w.text += c
                w.bare += c
                self.i += 1
        return w

    def double_quoted(self, w):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c == '"':
                self.i += 1
                return
            if c == "\\" and self.i + 1 < len(s):
                w.text += s[self.i + 1]
                self.i += 2
            elif c == "$":
                self.dollar(w, quoted=True)
            elif c == "`":
                self.backtick(w)
            else:
                w.text += c
                self.i += 1
        self.fail('a " that does not close')

    def dollar(self, w, quoted=False):
        s = self.s
        if not quoted and s.startswith("$'", self.i):
            # ANSI-C quoting: a literal, its escapes decoded (`$'\x70ublish'`
            # is `publish`).
            m = _ANSI_C.match(s, self.i)
            if m is None:
                self.fail("a $' that does not close")
            w.text += _decode_ansi_c(m.group(1))
            self.i = m.end()
            return
        w.expands = True
        if s.startswith("$((", self.i):
            depth = 0
            j = self.i + 1
            while j < len(s):
                if s[j] == "(":
                    depth += 1
                elif s[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= len(s):
                self.fail("a $(( that does not close")
            body = s[self.i + 3 : j - 1]
            if "$(" in body or "`" in body:
                w.subs += _substitutions(body)  # bash runs them in arithmetic
            w.text += s[self.i : j + 1]
            self.i = j + 1
        elif s.startswith("$(", self.i):
            start = self.i + 2
            inner = _Scanner(s)
            inner.i = start
            inner.events(stop=")")  # finds the matching `)`, quotes included
            w.subs.append(s[start : inner.i - 1])
            w.text += s[self.i : inner.i]
            self.i = inner.i
        elif s.startswith("${", self.i):
            j = s.find("}", self.i)
            if j < 0:
                self.fail("a ${ that does not close")
            body = s[self.i + 2 : j]
            if "$(" in body or "`" in body:
                # `${X:-$(…)}`: the default is a command bash runs. The body
                # may end inside it (`}` in the command); then the rest is
                # read as plain text, and the visible-text rule applies.
                w.subs += _substitutions(body)
            w.text += s[self.i : j + 1]
            self.i = j + 1
        else:
            w.text += "$"
            self.i += 1

    def backtick(self, w):
        s = self.s
        w.expands = True
        j = self.i + 1
        body = []
        while j < len(s) and s[j] != "`":
            if s[j] == "\\" and j + 1 < len(s):
                body.append(s[j + 1])
                j += 2
            else:
                body.append(s[j])
                j += 1
        if j >= len(s):
            self.fail("a ` that does not close")
        w.subs.append("".join(body))
        w.text += s[self.i : j + 1]
        self.i = j + 1


class _ScanError(Exception):
    pass


def _substitutions(body):
    """The command substitutions in [body], read as if double-quoted."""
    scanner = _Scanner('"' + body.replace('"', "'") + '"')
    return scanner.read_word().subs


def _resolve(target, base):
    """[target] from [base]; None for a target built from a variable."""
    if base is None or target.expands:
        return None
    path = os.path.expanduser(target.text)
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(base, path))


def _strip_wrappers(words, env, pub_in_text=True, moves=None):
    """The words after the assignments and wrappers in front of a command."""
    i = 0
    n = len(words)
    # Read once: a per-env scan of the rest would be quadratic.
    split_somewhere = any(
        w.text.startswith("--split-string")
        or (w.text.startswith("-") and not w.text.startswith("--") and "S" in w.text[1:])
        for w in words
    )

    def assignments():
        nonlocal i
        while i < n and words[i].assign_name:
            name = words[i].assign_name
            env[name] = words[i].text[len(name) + 1 :]
            i += 1

    def options(with_arg=()):
        nonlocal i
        while i < n and words[i].text.startswith("-") and words[i].text != "-":
            opt = words[i].text
            i += 1
            if opt == "--":
                return
            taken = [opt]
            if opt in with_arg and i < n:
                taken.append(words[i].text)
                i += 1
            # `env -S "dart pub publish"`, `--split-string=…`: a wrapper's
            # option that holds a command this reader does not run.
            if any(mentions_publish(t) for t in taken):
                raise PublishUnclear(
                    f"an option of `{os.path.basename(words[0].text)}` holds "
                    "`pub publish`"
                )

    while True:
        assignments()
        if i >= n:
            return []
        name = os.path.basename(words[i].text)
        if name in _KEYWORDS:
            i += 1
        elif name == "env":
            # `env -S "<command>"` splits a string into a command this reader
            # does not run: any -S/--split-string among env's words makes a
            # command that mentions `pub` unclear.
            if pub_in_text and split_somewhere:
                raise PublishUnclear("`env -S` splits a string into a command")
            i += 1
            # `env -C <dir>` / `--chdir`: the command runs in <dir>.
            k = i
            while k < n and words[k].text.startswith("-") and words[k].text != "--":
                t = words[k].text
                if t in ("-C", "--chdir") and k + 1 < n:
                    if moves is not None:
                        moves.append(words[k + 1])
                    k += 2
                    continue
                if t.startswith("--chdir=") or (t.startswith("-C") and len(t) > 2):
                    target = _Word()
                    target.text = t.split("=", 1)[1] if t.startswith("--") else t[2:]
                    target.expands = words[k].expands
                    if moves is not None:
                        moves.append(target)
                k += 1
            options(with_arg=("-u", "-C", "-S", "--split-string", "--chdir", "--unset"))
        elif name == "timeout":
            i += 1
            options(with_arg=("-s", "-k", "--signal", "--kill-after"))
            i += 1  # the duration
        elif name == "nice":
            i += 1
            options(with_arg=("-n",))
        elif name in ("nohup", "time", "builtin", "exec"):
            i += 1
            options()
        elif name == "command":
            i += 1
            if i < n and words[i].text in ("-v", "-V"):
                return []  # a lookup, not a run
            options()
        elif name == "stdbuf":
            i += 1
            options(with_arg=("-i", "-o", "-e"))
        elif name == "sudo":
            i += 1
            options(with_arg=("-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"))
        elif name == "fvm":
            i += 1
            if i < n and words[i].text == "exec":
                i += 1
            elif i < n and words[i].text == "spawn":
                i += 2
            elif not (i < n and words[i].text in ("dart", "flutter")):
                return words[i - 1 :]
        else:
            return words[i:]


def _publish_pairs(words):
    """Indexes i where words i+1, i+2 are `pub publish`."""
    return [
        k
        for k in range(len(words) - 2)
        if words[k + 1].text == "pub" and words[k + 2].text == "publish"
    ]


class _Reader:
    def __init__(self, text):
        self.text = text
        self.found = []

    def run(self, text, base, env, depth=0):
        # Where the command cannot be read, any sign of a publish in its text
        # (read loosely) is one; text with none is not.
        if depth > 20:
            if mentions_publish(text):
                raise PublishUnclear("commands nested more than 20 deep")
            return
        try:
            events = _Scanner(text).events()
        except _ScanError as e:
            if mentions_publish(text):
                raise PublishUnclear(f"the command cannot be read ({e})")
            return
        except RecursionError:
            if mentions_publish(text):
                raise PublishUnclear("the command nests too deep to read")
            return
        # The words of every command, quotes removed: what a reader sees.
        visible = _mentions_publish(
            " ".join(w.text for ev in events if ev not in ("open", "close") for w in ev[1].words)
        )
        # Per subshell: [directory, the && chain of a conditional cd, the
        # chain of the last cd].
        scopes = [[base, None, None]]
        chain = 0
        andor = 0  # an AND-OR list: commands joined by &&, || and pipes
        # Once an if/while/until/for/case has opened, a cd may sit in a branch
        # that did not run: every later cd is an unknown directory.
        block = False
        for ev in events:
            if ev == "open":
                scopes.append(list(scopes[-1]))
                continue
            if ev == "close":
                if len(scopes) > 1:
                    scopes.pop()
                continue
            cmd = ev[1]
            if cmd.before != "&&":
                chain += 1
            if cmd.before not in ("&&", "||", "|", "|&"):
                andor += 1
            scope = scopes[-1]
            if scope[1] is not None and scope[1] != chain:
                # `a && cd x; publish`: whether the cd ran is not known.
                scope[0] = None
                scope[1] = None
            here = scope[0]
            if cmd.after == "&" and scope[2] == andor:
                # `cd x && true &`: the whole list ran in the background.
                scope[0] = None
                scope[1] = None
                here = None
            if any(
                w.text in ("if", "while", "until", "for", "case", "select")
                for w in cmd.words
            ):
                block = True
            for word in cmd.words:
                for sub in word.subs:
                    self.run(sub, here, dict(env), depth + 1)
            own = dict(env)
            moves = []
            # `env -S`: unclear when its own words show a publish, or when one
            # of them expands and any of the text does (`env -S "$X"`, X set
            # elsewhere). `env -S 'echo hi'` beside a grep for `dart pub
            # publish` is clear.
            here_visible = _mentions_publish(" ".join(w.text for w in cmd.words)) or (
                visible and any(w.expands for w in cmd.words)
            )
            words = _strip_wrappers(cmd.words, own, here_visible, moves)
            for target in moves:
                here = _resolve(target, here)
            for body in cmd.heredocs:
                if words and os.path.basename(words[0].text) in _SHELLS and not any(
                    "c" in w.text[1:] for w in words[1:] if w.text.startswith("-")
                ):
                    self.run(body, here, own, depth + 1)
            if not words:
                continue
            name = os.path.basename(words[0].text)
            if name in _ENDS:
                continue
            if name in _SHELLS:
                script = None
                for k, w in enumerate(words[1:], 1):
                    if w.text.startswith("-") and "c" in w.text[1:] and not w.text.startswith("--"):
                        script = words[k + 1] if k + 1 < len(words) else None
                        break
                    if not w.text.startswith("-"):
                        break
                if script is not None:
                    self.run(script.text, here, own, depth + 1)
                    continue
                if len(words) == 1 or all(w.text.startswith("-") for w in words[1:]):
                    if not cmd.heredocs and mentions_publish(self.text):
                        raise PublishUnclear(
                            f"`{name}` reads its commands from stdin, which the "
                            "guard cannot see"
                        )
                continue
            if name == "eval":
                self.run(" ".join(w.text for w in words[1:]), here, own, depth + 1)
                continue
            if name in ("cd", "pushd", "popd"):
                args = words[1:]
                if (
                    name != "cd"
                    or len(args) != 1
                    or args[0].text.startswith("-")
                    # Piped or backgrounded: it runs in a subshell. After
                    # `||`, or inside a block: it may not run at all.
                    or cmd.after in ("|", "|&", "&")
                    or cmd.before in ("|", "|&", "||")
                    or block
                ):
                    scope[0] = None
                    scope[1] = None
                else:
                    scope[0] = _resolve(args[0], here)
                    # After `&&` it ran only if the chain before it did, which
                    # is known only for a publish in the same chain.
                    scope[1] = chain if cmd.before == "&&" else None
                    scope[2] = andor
                continue
            # A command or subcommand word that expands (`$D pub publish`,
            # `dart $SUB publish`, `{pub,publish}`) is unclear only when the
            # text, quotes removed, shows a publish: `$EDITOR "$FILE"` is not.
            # Any of it counts when any of the text shows a publish: a variable
            # set elsewhere can hold the rest (`$D --verbose $X`). So
            # `$FLUTTER test && git commit -m 'pub publish'` blocks, a false
            # block kept on purpose. Braces inside quotes do not expand.
            if visible and (
                words[0].expands
                or (name in ("dart", "flutter") and any(w.expands for w in words[1:3]))
                or any(_BRACES.search(w.bare) for w in words)
            ):
                raise PublishUnclear(
                    f"`{words[0].text}` runs a command or subcommand built from "
                    "a variable, a substitution or braces"
                )
            if name in ("dart", "flutter"):
                k = 1
                while k < len(words) and words[k].text.startswith("-"):
                    k += 1  # dart's own options, e.g. --verbose
                sub = _pub_subcommand(words, k)
                if sub is not None:
                    args = words[sub + 1 :]
                    self.found.append(
                        Publish(
                            own,
                            [w.text for w in args],
                            _directory(words[k + 1 :], here),
                        )
                    )
                    if any(_pub_subcommand(words, m) is not None for m in range(sub + 1, len(words))):
                        raise PublishUnclear("a second `pub publish` in one command")
                    continue
            if any(_pub_subcommand(words, m) is not None for m in range(len(words))):
                raise PublishUnclear(
                    f"`pub publish` behind `{words[0].text}`, which the guard "
                    "does not read"
                )


def _pub_subcommand(words, k):
    """The index of `publish|lish|lush` when words[k] is `pub` (or flutter's
    alias `packages`) followed by pub's global options and it; else None."""
    if k >= len(words) or words[k].text not in ("pub", "packages"):
        return None
    j = k + 1
    while j < len(words) and words[j].text.startswith("-"):
        j += 2 if words[j].text in ("-C", "--directory", "--verbosity") else 1
    if j < len(words) and words[j].text in _SUBCOMMANDS:
        return j
    return None


def _directory(args, base):
    """[base], moved by the LAST `-C`/`--directory` among pub's words, as pub
    itself takes the last one."""
    target = None
    for k, w in enumerate(args):
        t = w.text
        if t in ("-C", "--directory"):
            if k + 1 < len(args):
                target = args[k + 1]
        elif t.startswith("--directory="):
            target = _Word()
            target.text = t[len("--directory=") :]
            target.expands = w.expands
        elif t.startswith("-C") and len(t) > 2:
            target = _Word()
            target.text = t[2:]
            target.expands = w.expands
    return base if target is None else _resolve(target, base)


def publishes(cmd, cwd):
    """Every publish [cmd] runs from [cwd], in order.

    Raises PublishUnclear when [cmd] holds `pub publish` that cannot be read;
    a guard blocks on it.
    """
    reader = _Reader(cmd)
    try:
        reader.run(cmd, os.path.normpath(cwd) if cwd else None, {})
    except PublishUnclear:
        raise
    except Exception as e:  # noqa: BLE001 — a reader bug never lets a publish by
        if mentions_publish(cmd):
            raise PublishUnclear(f"the command could not be read ({e!r})")
        return []
    return reader.found


# ---------------------------------------------------------------- self-test

# (command, [directory of each publish, '' for dry runs]) or (command, None)
# when it must be unclear (a guard blocks). cwd is /r.
_CASES = [
    ("dart pub publish --force", ["/r"]),
    ("flutter pub publish", ["/r"]),
    ("cd packages/x && dart pub publish", ["/r/packages/x"]),
    ("cd packages/x\ndart pub publish", ["/r/packages/x"]),
    ("set -e\ncd packages/x\n  dart pub publish -f", ["/r/packages/x"]),
    ("timeout 900 dart pub publish", ["/r"]),
    ("PUB_HOSTED_URL=x dart pub publish", ["/r"]),
    ("cd x; (dart pub publish)", ["/r/x"]),
    ("dart pub publish --dry-run && dart pub publish", ["", "/r"]),
    ("dart pub publish --dry-run", [""]),
    ('echo \'{"command":"dart pub publish"}\' | cat', []),
    ('grep -r "dart pub publish" docs/', []),
    ("git push origin main", []),
    ('git commit -m "Run dart pub publish later"', []),
    ("cat <<'EOF'\ndart pub publish\nEOF", []),  # a heredoc body is data
    ("gh pr create --body \"$(cat <<'EOF'\ndart pub publish\nEOF\n)\"", []),
    ("bash <<'EOF'\ndart pub publish\nEOF", ["/r"]),  # a shell reads it
    # Directories.
    ("cd /w/b && dart pub publish", ["/w/b"]),
    ("dart pub publish\ncd /elsewhere", ["/r"]),
    ('cd "$PKG" && dart pub publish', [None]),
    ("cd $PKG && dart pub publish", [None]),
    ("dart pub publish -C /w/b --force", ["/w/b"]),
    ("cd packages && dart pub publish -C x", ["/r/packages/x"]),
    ("dart pub publish -Cpackages/x", ["/r/packages/x"]),
    ("dart pub publish --directory=packages/x", ["/r/packages/x"]),
    ("flutter pub publish --directory packages/x", ["/r/packages/x"]),
    ('dart pub publish -C "$PKG"', [None]),
    ("cd /w/b && cd - && dart pub publish", [None]),
    ("cd -P /w/b && dart pub publish", [None]),
    ("cd\ndart pub publish", [None]),
    ("pushd /w/b && dart pub publish", [None]),
    ("dart pub publish\ncd -", ["/r"]),
    ("(cd x) && dart pub publish", ["/r"]),  # the subshell's cd is gone
    ("cd a && dart pub publish -f && cd ../b && dart pub publish -f", ["/r/a", "/r/b"]),
    # Prefixes and wrappers.
    ('RELEASE_SKIP_REGISTRY="no device" dart pub publish -f', ["/r"]),
    ("RELEASE_SKIP_REGISTRY= dart pub publish", ["/r"]),
    ('env RELEASE_SKIP_REGISTRY="a b" X=1 dart pub publish', ["/r"]),
    ("FOO=$(pwd) dart pub publish", ["/r"]),
    ("FOO=$(a $(b) c) dart pub publish", ["/r"]),
    ("FOO=$(printf ')') dart pub publish", ["/r"]),
    ("FOO=`pwd` dart pub publish", ["/r"]),
    ("fvm dart pub publish", ["/r"]),
    ("fvm flutter pub publish -f", ["/r"]),
    ("sudo -u me dart pub publish", ["/r"]),
    ('bash -c "dart pub publish"', ["/r"]),
    ("bash -lc 'cd packages/x && dart pub publish'", ["/r/packages/x"]),
    ('eval "dart pub publish"', ["/r"]),
    ("echo $(dart pub publish)", ["/r"]),
    ("dart pub publish 2>&1 | tee log", ["/r"]),
    ("/usr/local/bin/dart pub publish", ["/r"]),
    # A cd that may not have run, or ran in a subshell.
    ("false && cd x; dart pub publish", [None]),
    ("cd x | cat; dart pub publish", [None]),
    ("cd x & dart pub publish", [None]),
    ("true || cd x; dart pub publish", [None]),
    ("if true; then cd x; fi; dart pub publish", [None]),
    ("if true\nthen\n  cd x\nfi\ndart pub publish", [None]),
    ("cd /w && git pull && cd x && dart pub publish", ["/w/x"]),
    ("cd x || exit 1; dart pub publish", ["/r/x"]),
    ("cd x && echo hi; dart pub publish", ["/r/x"]),
    # Unclear: blocked.
    ('env -S "dart pub publish"', None),
    ("env -S'dart pub publish'", None),
    ("env -iS 'dart pub publish'", None),
    ("timeout -s 'dart pub publish' 5 ls", None),
    ("env -u X -S 'dart pub publish'", None),
    ("env -C /tmp -S 'dart pub publish'", None),
    ("cd x || true && true & dart pub publish", [None]),
    ("cd x | cat && true & dart pub publish", [None]),
    ("time if true; then cd x; fi; dart pub publish", [None]),
    ("P=publish; $D pub $P", None),
    ("X=pub; $D $X publish", None),
    ("X='dart pub publish'; $X", None),
    ("dart $X", []),  # nothing visible says publish
    # Out of scope (deliberate disguise): only part of the publish is visible.
    ('env --split-string "dart pub $P"', []),
    ("dart $SUB publish", []),
    ("$D pub $P", []),
    ("$D $P", []),
    ("cd x && true & dart pub publish", [None]),
    ("{ if true; then cd x; fi; }; dart pub publish", [None]),
    ("! if true; then cd x; fi; dart pub publish", [None]),
    ("cd x; if true; then echo; fi; dart pub publish", ["/r/x"]),
    ("echo $X", []),
    ("env --split-string='dart pub publish'", None),
    ("dart pub $(echo publish)", None),
    ("xargs dart pub publish", None),
    # pub's aliases, global options and directories.
    ("dart pub lish --force", ["/r"]),
    ("dart pub lush --force", ["/r"]),
    ("dart pub -v publish --force", ["/r"]),
    ("dart --verbose pub publish", ["/r"]),
    ("dart pub -C packages/x publish --force", ["/r/packages/x"]),
    ("dart pub publish -C a -C b --force", ["/r/b"]),
    ("dart pub -C a publish --directory=b", ["/r/b"]),
    ("env -C /w dart pub publish", ["/w"]),
    ("env --chdir=/w dart pub publish", ["/w"]),
    ("env -C $D dart pub publish", [None]),
    ("dart pub lish --dry-run", [""]),
    ("xargs dart pub -v lish", None),
    # Substitutions inside arithmetic and parameter defaults run.
    ("echo $(( $(dart pub publish) ))", ["/r"]),
    ("echo ${X:-$(dart pub publish)}", ["/r"]),
    # Braces that could spell a publish.
    ("dart {pub,publish} --force", None),
    # Ordinary commands with an expanding name are not a publish.
    ('$EDITOR "$FILE"', []),
    ('${DART:-dart} format "$F"', []),
    ("$(git rev-parse --show-toplevel)/tool/test_all.sh $PKG", []),
    ("dart $SCRIPT", []),
    ("d=dart; $d pub publish", None),
    ("echo 'dart pub publish' | sh", None),
    ('dart pub publish "unclosed', None),
    ("FOO=$(a dart pub publish", None),
    # flutter's `packages` alias, ANSI-C quoting, and the aliases on paths
    # that cannot read the command.
    ("flutter packages publish --force", ["/r"]),
    ("flutter packages -v lish", ["/r"]),
    ("dart pub $'\\x70ublish' --force", ["/r"]),
    ("dart $'\\160ub' publish", ["/r"]),
    ('echo "$\'dart pub publish\'"', []),  # not ANSI-C inside double quotes
    ("bash <<< 'dart pub lish --force'", None),
    ("echo 'dart pub lish --force' | sh", None),
    ('dart pub -v publish -f\necho "x', None),  # bash runs line 1 first
    ("env -S 'dart pub lish'", None),
    # Not a publish: no false blocks.
    ("git commit -m 'fix {a,b} before dart pub publish'", []),
    ("env -S 'echo hi'; grep -r 'dart pub publish' docs", []),
    # Kept blocked: a variable set elsewhere can hold the rest of a publish.
    ("$FLUTTER test && git commit -m 'prep pub publish'", None),
    ("D=dart; X='pub publish'; $D --verbose $X", None),
    ("X='dart pub publish'; env -S \"$X\"", None),
    # An escape past U+10FFFF is kept as written, never a crash.
    ("echo $'\\U7fffffff'", []),
    ("dart pub publish $'\\U7fffffff'", ["/r"]),
    ("echo " + "$(echo " * 21 + "x" + ")" * 21, []),
    ("echo " + "$(echo " * 21 + "dart pub publish" + ")" * 21, None),
]


def self_test():
    """Failures, as text; [] when every case holds."""
    import time

    bad = []
    for cmd, want in _CASES:
        try:
            got = [("" if p.dry_run else p.directory) for p in publishes(cmd, "/r")]
        except PublishUnclear:
            got = None
        if want is not None:
            want = [w if w in ("", None) else os.path.normpath(w) for w in want]
        if got != want:
            bad.append(f"{cmd!r}: {got!r}, want {want!r}")
    p = publishes('RELEASE_SKIP_REGISTRY="no device" X=1 dart pub publish', "/r")[0]
    if p.skip_reason("RELEASE_SKIP_REGISTRY") != "no device":
        bad.append("a quoted skip reason is not read")
    for cmd in (
        "RELEASE_SKIP_REGISTRY= dart pub publish",
        'RELEASE_SKIP_REGISTRY="  " dart pub publish',
        "RELEASE_SKIP_REGISTRY=x echo hi && dart pub publish",
        "export RELEASE_SKIP_REGISTRY=x; dart pub publish",
    ):
        if publishes(cmd, "/r")[-1].skip_reason("RELEASE_SKIP_REGISTRY"):
            bad.append(f"{cmd!r}: counted as a skip")
    if not publishes('bash -c "dart pub publish"', "/r")[0].env == {}:
        bad.append("bash -c invents env")
    if publishes('RELEASE_SKIP_REGISTRY=r bash -c "dart pub publish"', "/r")[0].skip_reason(
        "RELEASE_SKIP_REGISTRY"
    ) != "r":
        bad.append("an env prefix does not reach the publish inside bash -c")
    # Linear: a long prefix that is no publish, and one in front of a publish.
    for n in (40, 4000):
        for cmd in ("env a=b " * n + "x", "env a=b " * n + "x; dart pub publish"):
            t = time.perf_counter()
            try:
                publishes(cmd, "/r")
            except PublishUnclear:
                pass
            took = time.perf_counter() - t
            if took > (0.05 if n == 40 else 0.5):
                bad.append(f"{n} env prefixes took {took:.3f} s")
    # A bug in the reader: a publish is unclear, anything else is not one.
    real_run = _Reader.run

    def broken(self, *args, **kwargs):
        raise ValueError("reader bug")

    _Reader.run = broken
    try:
        try:
            publishes("dart pub publish", "/r")
            bad.append("a reader bug let a publish through")
        except PublishUnclear:
            pass
        if publishes("git status", "/r") != []:
            bad.append("a reader bug on a plain command is not []")
    finally:
        _Reader.run = real_run
    return bad
