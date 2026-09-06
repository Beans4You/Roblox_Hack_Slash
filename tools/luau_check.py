#!/usr/bin/env python3
"""
Structural checker for the Luau sources in this repository.

WHAT THIS IS
    A dependency-free lexer plus block-balance checker. It tokenises Luau
    properly -- long strings and long comments with any level of `=` padding,
    quoted strings with escapes, numbers, and Luau's type-annotation syntax --
    then verifies that every block keyword is matched and every bracket closes.

WHAT THIS IS NOT
    A Luau compiler. It does not type-check, resolve requires, or validate
    expressions. It catches the class of error that is actually easy to
    introduce in a file of this size and invisible in review: an unbalanced
    `end`, a table brace left open, a string that swallows the rest of a file.

    Run `rojo build` and open the place in Studio for real validation.

USAGE
    python3 tools/luau_check.py [path ...]      # defaults to src/
    Exit status is non-zero if any problem is found, so it works in CI.
"""

from __future__ import annotations

import sys
import pathlib
from dataclasses import dataclass

KEYWORDS_OPEN = {"function", "if", "for", "while", "do", "repeat"}
KEYWORDS_CLOSE = {"end", "until"}


@dataclass
class Token:
    kind: str      # "name", "keyword", "string", "number", "op"
    value: str
    line: int


class LexError(Exception):
    def __init__(self, message: str, line: int):
        super().__init__(message)
        self.message = message
        self.line = line


LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
    # Luau contextual keywords that matter to us
    "continue", "export", "type",
}


def _long_bracket(text: str, i: int) -> tuple[int, int] | None:
    """If text[i:] opens a long bracket ([[ , [=[ , [==[ ...), return (level, start_of_body)."""
    if text[i] != "[":
        return None
    j = i + 1
    level = 0
    while j < len(text) and text[j] == "=":
        level += 1
        j += 1
    if j < len(text) and text[j] == "[":
        return level, j + 1
    return None


def tokenize(text: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    line = 1
    n = len(text)

    while i < n:
        c = text[i]

        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r":
            i += 1
            continue

        # Comments (must be checked before the '-' operator).
        if text.startswith("--", i):
            long_open = _long_bracket(text, i + 2)
            if long_open is not None:
                level, body = long_open
                close = "]" + "=" * level + "]"
                end = text.find(close, body)
                if end == -1:
                    raise LexError("unterminated long comment", line)
                line += text.count("\n", i, end)
                i = end + len(close)
            else:
                end = text.find("\n", i)
                i = n if end == -1 else end
            continue

        # Long strings.
        long_open = _long_bracket(text, i)
        if long_open is not None:
            level, body = long_open
            close = "]" + "=" * level + "]"
            end = text.find(close, body)
            if end == -1:
                raise LexError("unterminated long string", line)
            start_line = line
            line += text.count("\n", i, end)
            tokens.append(Token("string", text[body:end], start_line))
            i = end + len(close)
            continue

        # Quoted strings.
        if c in "\"'":
            quote = c
            j = i + 1
            start_line = line
            while j < n:
                if text[j] == "\\":
                    if j + 1 < n and text[j + 1] == "\n":
                        line += 1
                    j += 2
                    continue
                if text[j] == "\n":
                    raise LexError(f"unterminated {quote}-string", start_line)
                if text[j] == quote:
                    break
                j += 1
            if j >= n:
                raise LexError(f"unterminated {quote}-string", start_line)
            tokens.append(Token("string", text[i + 1:j], start_line))
            i = j + 1
            continue

        # Numbers (including hex and scientific notation).
        if c.isdigit() or (c == "." and i + 1 < n and text[i + 1].isdigit()):
            j = i
            if text.startswith(("0x", "0X"), i):
                j = i + 2
                while j < n and (text[j] in "0123456789abcdefABCDEF_"):
                    j += 1
            else:
                seen_e = False
                while j < n:
                    ch = text[j]
                    if ch.isdigit() or ch in "._":
                        j += 1
                    elif ch in "eE" and not seen_e:
                        seen_e = True
                        j += 1
                        if j < n and text[j] in "+-":
                            j += 1
                    else:
                        break
            tokens.append(Token("number", text[i:j], line))
            i = j
            continue

        # Names and keywords.
        if c.isalpha() or c == "_":
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            word = text[i:j]
            tokens.append(Token("keyword" if word in LUA_KEYWORDS else "name", word, line))
            i = j
            continue

        # Operators and punctuation.
        for op in ("...", "..", "::", "->", "==", "~=", "<=", ">=", "//"):
            if text.startswith(op, i):
                tokens.append(Token("op", op, line))
                i += len(op)
                break
        else:
            tokens.append(Token("op", c, line))
            i += 1

    return tokens


@dataclass
class Block:
    keyword: str
    line: int
    awaiting_do: bool = False


def check_blocks(tokens: list[Token], path: str) -> list[str]:
    problems: list[str] = []
    stack: list[Block] = []
    # Bracket stack tracks (char, line) so an unclosed one can be reported precisely.
    brackets: list[tuple[str, int]] = []
    pairs = {")": "(", "]": "[", "}": "{"}

    # Luau has an if-EXPRESSION (`local x = if c then a else b`) which, unlike the
    # if-statement, has no `end`. The two are told apart by what precedes them: an
    # expression-if only ever appears where a value is expected.
    VALUE_CONTEXT_OPS = {
        "=", "(", ",", "{", "[", "..", "==", "~=", "<", ">", "<=", ">=",
        "+", "-", "*", "/", "%", "^", "::", "->",
    }
    VALUE_CONTEXT_KEYWORDS = {"return", "and", "or", "not"}

    prev: Token | None = None

    for token in tokens:
        if token.kind == "op":
            if token.value in "([{":
                brackets.append((token.value, token.line))
            elif token.value in ")]}":
                if not brackets:
                    problems.append(f"{path}:{token.line}: stray '{token.value}'")
                elif brackets[-1][0] != pairs[token.value]:
                    opener, opened_at = brackets[-1]
                    problems.append(
                        f"{path}:{token.line}: '{token.value}' closes '{opener}' opened at line {opened_at}"
                    )
                    brackets.pop()
                else:
                    brackets.pop()
            prev = token
            continue

        if token.kind != "keyword":
            prev = token
            continue

        word = token.value

        if word == "if":
            is_expression = prev is not None and (
                (prev.kind == "op" and prev.value in VALUE_CONTEXT_OPS)
                or (prev.kind == "keyword" and prev.value in VALUE_CONTEXT_KEYWORDS)
            )
            if not is_expression:
                stack.append(Block("if", token.line))
        elif word == "function":
            stack.append(Block(word, token.line))
        elif word in ("for", "while"):
            stack.append(Block(word, token.line, awaiting_do=True))
        elif word == "do":
            # A `do` belonging to the for/while directly above it closes that
            # block's header rather than opening a new one.
            if stack and stack[-1].awaiting_do:
                stack[-1].awaiting_do = False
            else:
                stack.append(Block("do", token.line))
        elif word == "repeat":
            stack.append(Block("repeat", token.line))
        elif word == "end":
            if not stack:
                problems.append(f"{path}:{token.line}: 'end' with no open block")
            elif stack[-1].keyword == "repeat":
                problems.append(
                    f"{path}:{token.line}: 'end' closing a 'repeat' opened at line {stack[-1].line}"
                    " (expected 'until')"
                )
                stack.pop()
            else:
                stack.pop()
        elif word == "until":
            if not stack:
                problems.append(f"{path}:{token.line}: 'until' with no open block")
            elif stack[-1].keyword != "repeat":
                problems.append(
                    f"{path}:{token.line}: 'until' closing a '{stack[-1].keyword}'"
                    f" opened at line {stack[-1].line}"
                )
                stack.pop()
            else:
                stack.pop()

        prev = token

    for block in stack:
        problems.append(f"{path}:{block.line}: '{block.keyword}' is never closed")
    for opener, opened_at in brackets:
        problems.append(f"{path}:{opened_at}: '{opener}' is never closed")

    return problems


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    try:
        tokens = tokenize(text)
    except LexError as error:
        return [f"{path}:{error.line}: {error.message}"]

    problems = check_blocks(tokens, str(path))

    # Every module in this project is a ModuleScript or a *.server/*.client script.
    # A ModuleScript that forgets to return is a silent, confusing runtime failure.
    name = path.name
    is_script = name.endswith(".server.lua") or name.endswith(".client.lua")
    if not is_script:
        returns_at_top = any(
            line.startswith("return ")
            for line in text.splitlines()
        )
        if not returns_at_top:
            problems.append(f"{path}: ModuleScript never returns anything")

    return problems


def main(argv: list[str]) -> int:
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path("src")]
    files: list[pathlib.Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(sorted(root.rglob("*.lua")))
        elif root.suffix == ".lua":
            files.append(root)

    if not files:
        print("no .lua files found", file=sys.stderr)
        return 1

    all_problems: list[str] = []
    for path in files:
        all_problems.extend(check_file(path))

    for problem in all_problems:
        print(problem)

    print(f"\n{len(files)} file(s) checked, {len(all_problems)} problem(s) found.")
    return 1 if all_problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
