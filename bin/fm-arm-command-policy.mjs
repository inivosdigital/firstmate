#!/usr/bin/env node
// Semantic policy for watcher arm and checkpoint shell commands.
//
// This parser is deliberately narrow.
// It recognizes executed command positions without evaluating, expanding,
// sourcing, or running any byte of the submitted command.
//
// This file is the sole owner of firstmate's shell command classification.
// The tokenizer and command-position analysis (Lexer, splitProgram,
// commandPosition) are exported so the sibling cd-guard policy
// (bin/fm-cd-command-policy.mjs) reuses the same proven parser instead of
// duplicating shell lexing; see docs/cd-guard.md. The watcher-arm decision
// procedure below stays private to this file, including splitBlockProgram,
// which extends splitProgram with the `if`, `for`, `while`, `until`, and `case`
// constructs so their bodies are classified by command position rather than
// falling back to a raw whole-string match. The CLI entry point at the bottom
// runs only when this module is invoked directly, never on import.
//
// Two properties hold this together once a program branches or loops, and both
// are load-bearing. The variable model is a may-analysis: it may conclude that a
// name is possibly dangerous, never that it is safe, so taint accumulates and no
// branch, later assignment, or line ordering ever removes it. And because
// parsing a construct is not understanding it, a block program that produced no
// refusal is still handed to the unchanged raw check, over the part of itself
// that runs.
//
// Only two kinds of byte are held back from that check: a comment, and a
// here-document body under a quoted delimiter going to a command that reads its
// input and nothing else. Both are text the shell itself is required to leave
// inert, not text this parser has concluded is harmless, which is a weaker
// thing and was twice wrong. See docs/arm-pretool-check.md "Block constructs".

import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "watcher-background": "a protected watcher command cannot run in an asynchronous shell list or through nohup/disown",
  "watcher-pipeline": "a protected watcher command must not participate in a pipeline",
  "watcher-redirection": "a protected watcher command must not use shell redirection",
  "watcher-bundled": "a protected watcher command must be the sole final command after approved setup nodes",
  "watcher-nested": "a protected watcher command must not run through a wrapper, substitution, or compound command",
  "broad-watcher-kill": "a broad process kill targeting the firstmate watcher is forbidden",
  "unclassifiable-protected-command": "unsupported or malformed shell syntax contains a protected watcher command",
  "watcher-direct": "bin/fm-watch.sh must not be run directly; arm the watcher with bin/fm-watch-arm.sh or run bin/fm-watch-checkpoint.sh instead",
};

function parseArguments(argv) {
  const result = { command: "", root: "", home: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--root" || name === "--home") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      result[name.slice(2)] = argv[i + 1];
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function rawMentionsProtected(command) {
  return /(?:^|[/\s'"`(])fm-watch(?:-(?:arm|checkpoint))?\.sh\b/.test(normalizeLineContinuations(command));
}

function rawMentionsBroadKill(command) {
  const normalized = normalizeLineContinuations(command);
  return /fm-watch/.test(normalized) && /\b(?:pkill|kill)\b/.test(normalized);
}

function normalizeLineContinuations(source) {
  return source.replace(/\\\r?\n/g, "");
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function extractBalanced(source, start, open, close) {
  let depth = 1;
  let quote = "";
  let escaped = false;
  for (let i = start; i < source.length; i += 1) {
    const char = source[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote === "'") {
      if (char === "'") quote = "";
      continue;
    }
    if (quote === '"') {
      if (char === "\\") {
        escaped = true;
      } else if (char === '"') {
        quote = "";
      }
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (char === open) depth += 1;
    if (char === close) {
      depth -= 1;
      if (depth === 0) return { content: source.slice(start, i), next: i + 1 };
    }
  }
  return null;
}

function extractBackticks(source, start) {
  let escaped = false;
  for (let i = start; i < source.length; i += 1) {
    const char = source[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === "`") return { content: source.slice(start, i), next: i + 1 };
  }
  return null;
}

function decodeAnsiCQuoted(source, start) {
  let index = start + 2;
  let value = "";
  while (index < source.length) {
    const char = source[index];
    if (char === "'") return { value, next: index + 1 };
    if (char !== "\\") {
      value += char;
      index += 1;
      continue;
    }
    if (index + 1 >= source.length) return null;
    const escape = source[index + 1];
    index += 2;
    const simple = { a: "\u0007", b: "\b", e: "\u001b", E: "\u001b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v", "\\": "\\", "'": "'", '"': '"', "?": "?" };
    if (Object.hasOwn(simple, escape)) {
      value += simple[escape];
      continue;
    }
    if (/[0-7]/.test(escape)) {
      let digits = escape;
      while (digits.length < 3 && /[0-7]/.test(source[index] || "")) {
        digits += source[index];
        index += 1;
      }
      value += String.fromCodePoint(Number.parseInt(digits, 8));
      continue;
    }
    if (escape === "x") {
      let digits = "";
      while (digits.length < 2 && /[0-9A-Fa-f]/.test(source[index] || "")) {
        digits += source[index];
        index += 1;
      }
      value += digits ? String.fromCodePoint(Number.parseInt(digits, 16)) : "\\x";
      continue;
    }
    if (escape === "u" || escape === "U") {
      const length = escape === "u" ? 4 : 8;
      const digits = source.slice(index, index + length);
      if (digits.length === length && /^[0-9A-Fa-f]+$/.test(digits)) {
        const codePoint = Number.parseInt(digits, 16);
        try {
          value += String.fromCodePoint(codePoint);
          index += length;
          continue;
        } catch {}
      }
      value += `\\${escape}`;
      continue;
    }
    if (escape === "c" && index < source.length) {
      value += String.fromCodePoint(source.codePointAt(index) & 31);
      index += 1;
      continue;
    }
    value += `\\${escape}`;
  }
  return null;
}

const CONTROL_OPERATORS = ["&&", "||", "|&", ";;", ";", "&", "|"];
const BLOCK_CONTROL_OPERATORS = [...CONTROL_OPERATORS, ")"];

export class Lexer {
  // options.blocks admits `)` as a control operator so `case` arm patterns
  // tokenize. It is opt-in because the cd-guard deliberately fails open on
  // input it cannot tokenize, so widening its tokenizer would silently move
  // cd verdicts. Only the watcher policy below, which fails closed, asks for it.
  constructor(source, options = {}) {
    this.source = source;
    this.index = 0;
    this.error = "";
    this.tokens = [];
    this.pendingHeredocs = [];
    this.expectHeredoc = null;
    this.blocks = options.blocks === true;
    // Where the comments were. They are dropped rather than tokenized, so a
    // caller that wants to know which bytes of the source do not run has to be
    // told; nothing else can recover them afterwards.
    this.comments = [];
  }

  tokenize() {
    while (this.index < this.source.length && !this.error) {
      const char = this.source[this.index];
      if (char === " " || char === "\t" || char === "\r") {
        this.index += 1;
        continue;
      }
      if (char === "#") {
        this.skipComment();
        continue;
      }
      if (char === "\n") {
        this.tokens.push({ type: "op", value: "newline" });
        this.index += 1;
        if (this.pendingHeredocs.length > 0) this.skipHeredocBodies();
        continue;
      }
      const control = this.readControlOperator();
      if (control) {
        this.tokens.push({ type: "op", value: control });
        continue;
      }
      const redirection = this.readRedirection();
      if (redirection) {
        const token = { type: "redir", value: redirection.value, inlineTarget: redirection.inlineTarget, fd: redirection.fd };
        this.tokens.push(token);
        if (redirection.value === "<<" || redirection.value === "<<-") this.expectHeredoc = { token, stripTabs: redirection.value === "<<-" };
        continue;
      }
      if (char === "(" || char === "{") {
        const close = char === "(" ? ")" : "}";
        const balanced = extractBalanced(this.source, this.index + 1, char, close);
        if (!balanced) {
          this.error = `unclosed ${char}`;
          break;
        }
        this.tokens.push({ type: "group", kind: char === "(" ? "subshell" : "brace", content: balanced.content });
        this.index = balanced.next;
        continue;
      }
      const word = this.readWord();
      if (!word) {
        this.error = `unsupported token at byte ${this.index}`;
        break;
      }
      this.tokens.push(word);
      if (this.expectHeredoc) {
        // Whether any part of the delimiter was quoted, which decides what the
        // shell does to the body. With no part of it quoted the body is subject
        // to parameter expansion, command substitution and arithmetic expansion
        // before the reading command is ever reached, so `<<EOF` holding
        // `$(...)` runs it and `<<'EOF'` holding the same text does not.
        this.expectHeredoc.token.heredocQuoted = word.quoted;
        this.pendingHeredocs.push({ delimiter: word.value, stripTabs: this.expectHeredoc.stripTabs, token: this.expectHeredoc.token });
        this.expectHeredoc = null;
      }
    }
    if (this.expectHeredoc) this.error = "missing heredoc delimiter";
    return { tokens: this.tokens, comments: this.comments, error: this.error };
  }

  skipComment() {
    const start = this.index;
    while (this.index < this.source.length && this.source[this.index] !== "\n") this.index += 1;
    this.comments.push([start, this.index]);
  }

  skipHeredocBodies() {
    for (const heredoc of this.pendingHeredocs) {
      const start = this.index;
      let found = false;
      let body = "";
      while (this.index < this.source.length) {
        const end = this.source.indexOf("\n", this.index);
        const lineEnd = end === -1 ? this.source.length : end;
        const line = this.source.slice(this.index, lineEnd);
        const comparable = heredoc.stripTabs ? line.replace(/^\t+/, "") : line;
        this.index = end === -1 ? this.source.length : end + 1;
        if (comparable === heredoc.delimiter) {
          found = true;
          break;
        }
        body += comparable;
        if (end !== -1) body += "\n";
      }
      if (!found) {
        this.error = "unclosed heredoc";
        break;
      }
      heredoc.token.heredoc = body;
      // Where the body and its terminator sit in the source, so a caller that
      // has decided a body is data can take it back out of the raw text.
      heredoc.token.heredocRange = [start, this.index];
    }
    this.pendingHeredocs = [];
  }

  readControlOperator() {
    for (const operator of this.blocks ? BLOCK_CONTROL_OPERATORS : CONTROL_OPERATORS) {
      if (this.source.startsWith(operator, this.index)) {
        this.index += operator.length;
        return operator;
      }
    }
    return "";
  }

  readRedirection() {
    const remaining = this.source.slice(this.index);
    const match = remaining.match(/^(\d+)?(<<<|<<-|<<|>>|<>|>&|<&|>|<)(?:&?[0-9-]+)?/);
    if (!match) return "";
    this.index += match[0].length;
    const inlineTarget = /(?:>&|<&)[0-9-]+$/.test(match[0]);
    let normalized = match[0].replace(/^\d+/, "");
    if (inlineTarget) normalized = normalized.replace(/[0-9-]+$/, "");
    const fd = match[1] === undefined ? (match[2].startsWith("<") ? 0 : 1) : Number(match[1]);
    return { value: normalized, inlineTarget, fd };
  }

  readWord() {
    const word = { type: "word", value: "", literal: true, subs: [], quoted: false, unquotedExpansion: false };
    let consumed = false;
    while (this.index < this.source.length) {
      const char = this.source[this.index];
      if (/\s/.test(char) || ";&|<>()".includes(char)) break;
      if (char === "#" && !consumed) break;
      consumed = true;
      if (char === "'") {
        word.quoted = true;
        const end = this.source.indexOf("'", this.index + 1);
        if (end === -1) {
          this.error = "unclosed single quote";
          return null;
        }
        word.value += this.source.slice(this.index + 1, end);
        this.index = end + 1;
        continue;
      }
      if (char === '"') {
        word.quoted = true;
        if (!this.readDoubleQuoted(word)) return null;
        continue;
      }
      if (char === "\\") {
        if (this.index + 1 >= this.source.length) {
          this.error = "trailing escape";
          return null;
        }
        if (this.source[this.index + 1] === "\n") {
          this.index += 2;
          continue;
        }
        word.value += this.source[this.index + 1];
        this.index += 2;
        continue;
      }
      if (this.source.startsWith("$'", this.index)) {
        const ansi = decodeAnsiCQuoted(this.source, this.index);
        if (!ansi) {
          this.error = "unclosed ANSI-C quote";
          return null;
        }
        word.quoted = true;
        word.value += ansi.value;
        this.index = ansi.next;
        continue;
      }
      if (this.source.startsWith('$"', this.index)) {
        word.quoted = true;
        this.index += 1;
        if (!this.readDoubleQuoted(word)) return null;
        continue;
      }
      if (this.source.startsWith("$(", this.index)) {
        const balanced = extractBalanced(this.source, this.index + 2, "(", ")");
        if (!balanced) {
          this.error = "unclosed command substitution";
          return null;
        }
        word.subs.push({ kind: "command", content: balanced.content });
        word.literal = false;
        this.index = balanced.next;
        continue;
      }
      if ((char === "<" || char === ">") && this.source[this.index + 1] === "(") {
        const balanced = extractBalanced(this.source, this.index + 2, "(", ")");
        if (!balanced) {
          this.error = "unclosed process substitution";
          return null;
        }
        word.subs.push({ kind: "process", content: balanced.content });
        word.literal = false;
        this.index = balanced.next;
        continue;
      }
      if (char === "`") {
        const backticks = extractBackticks(this.source, this.index + 1);
        if (!backticks) {
          this.error = "unclosed backtick substitution";
          return null;
        }
        word.subs.push({ kind: "command", content: backticks.content });
        word.literal = false;
        this.index = backticks.next;
        continue;
      }
      if (char === "$") word.literal = false;
      if ("*?[]{}".includes(char)) word.unquotedExpansion = true;
      word.value += char;
      this.index += 1;
    }
    return consumed ? word : null;
  }

  readDoubleQuoted(word) {
    this.index += 1;
    while (this.index < this.source.length) {
      const char = this.source[this.index];
      if (char === '"') {
        this.index += 1;
        return true;
      }
      if (char === "\\") {
        if (this.index + 1 >= this.source.length) break;
        if (this.source[this.index + 1] === "\n") {
          this.index += 2;
          continue;
        }
        word.value += this.source[this.index + 1];
        this.index += 2;
        continue;
      }
      if (this.source.startsWith("$(", this.index)) {
        const balanced = extractBalanced(this.source, this.index + 2, "(", ")");
        if (!balanced) break;
        word.subs.push({ kind: "command", content: balanced.content });
        word.literal = false;
        this.index = balanced.next;
        continue;
      }
      if (char === "`") {
        const backticks = extractBackticks(this.source, this.index + 1);
        if (!backticks) break;
        word.subs.push({ kind: "command", content: backticks.content });
        word.literal = false;
        this.index = backticks.next;
        continue;
      }
      if (char === "$") word.literal = false;
      word.value += char;
      this.index += 1;
    }
    this.error = "unclosed double quote";
    return false;
  }
}

export function splitProgram(tokens) {
  const nodes = [];
  const separators = [];
  let current = [];
  for (const token of tokens) {
    if (token.type === "op") {
      if (current.length > 0) {
        nodes.push(current);
        current = [];
        separators.push(token.value);
      } else if (token.value !== "newline") {
        separators.push(token.value);
      }
      continue;
    }
    current.push(token);
  }
  if (current.length > 0) nodes.push(current);
  while (separators.length >= nodes.length && separators.at(-1) === "newline") separators.pop();
  return { nodes, separators };
}

// Reserved words that open, continue, or close a shell block construct.
// They are only reserved in command position and only unquoted and unexpanded,
// so `echo done` and `'while' x` stay ordinary commands.
const BLOCK_WORDS = new Set(["if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac"]);

function blockKeyword(token) {
  if (!token || token.type !== "word" || token.quoted || !token.literal || token.subs.length > 0) return "";
  return BLOCK_WORDS.has(token.value) ? token.value : "";
}

// splitProgram plus the block constructs `if/elif/else/fi`, `for/while/until
// ... do ... done`, and `case ... esac`, including nesting.
//
// Structural keywords are consumed rather than emitted, so each construct's
// condition, body, and arm commands arrive as ordinary simple-command nodes and
// the consumer-aware analysis downstream applies to them unchanged. A `for`
// header is emitted as a "for-list" node: a word list is not an executed
// command, but its substitutions still run and its loop variable still binds.
//
// The scanner validates the construct's shape. Anything it cannot fit into a
// well-formed construct sets `error` and returns the plain splitProgram result,
// which leaves the caller on exactly the conservative path it uses today.
function splitBlockProgram(tokens) {
  const nodes = [];
  const separators = [];
  const roles = [];
  const loopVariables = [];
  const adjacency = [];
  const stack = [];
  let current = [];
  let header = null;
  let subject = null;
  let patternOpen = false;
  let hasBlocks = false;
  let lastSeparator = "";
  let error = "";

  const fail = (message) => {
    if (!error) error = message;
  };
  const top = () => stack.at(-1);
  const emit = (role, loopVariable) => {
    nodes.push(current);
    roles.push(role);
    loopVariables.push(loopVariable || "");
    // The operators immediately either side of this node. `separators` is a
    // program-wide list that does not line up with `nodes` once structural
    // keywords come and go, and callers need to know whether a given node is
    // handing its output to another command.
    adjacency.push({ before: lastSeparator, after: "" });
    current = [];
  };
  const closeSimple = (separator) => {
    if (current.length > 0) {
      emit("command");
      separators.push(separator);
      adjacency.at(-1).after = separator;
    } else if (separator !== "newline") {
      separators.push(separator);
    }
    lastSeparator = separator;
  };

  for (const token of tokens) {
    if (error) break;

    if (header) {
      if (token.type === "op") {
        if (token.value !== ";" && token.value !== "newline") {
          fail("unsupported for header");
          break;
        }
        current = header.words;
        emit("for-list", header.variable);
        separators.push(token.value);
        adjacency.at(-1).after = token.value;
        lastSeparator = token.value;
        header = null;
        continue;
      }
      if (token.type !== "word") {
        fail("unsupported for header");
        break;
      }
      if (!header.variable) {
        if (!token.literal || token.quoted || token.subs.length > 0 || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(token.value)) {
          fail("unsupported for variable");
          break;
        }
        header.variable = token.value;
        continue;
      }
      if (!header.sawIn) {
        if (token.value !== "in" || token.quoted || !token.literal) {
          fail("unsupported for header");
          break;
        }
        header.sawIn = true;
        continue;
      }
      header.words.push(token);
      continue;
    }

    if (subject) {
      if (token.type !== "word" || token.subs.length > 0) {
        fail("unsupported case subject");
        break;
      }
      if (!subject.word) {
        subject.word = token;
        continue;
      }
      if (token.value !== "in" || token.quoted || !token.literal) {
        fail("unsupported case subject");
        break;
      }
      subject = null;
      patternOpen = true;
      continue;
    }

    if (patternOpen) {
      if (current.length === 0 && blockKeyword(token) === "esac") {
        if (top()?.type !== "case") {
          fail("unexpected esac");
          break;
        }
        stack.pop();
        patternOpen = false;
        continue;
      }
      if (token.type === "op") {
        if (token.value === ")") {
          if (top()?.type !== "case") {
            fail("unexpected )");
            break;
          }
          current = [];
          patternOpen = false;
          top().phase = "body";
          continue;
        }
        if (token.value === "newline" && current.length === 0) continue;
        if (token.value === "|" && current.length > 0) continue;
        fail("unsupported case pattern");
        break;
      }
      if (token.type !== "word" || token.subs.length > 0) {
        fail("unsupported case pattern");
        break;
      }
      current.push(token);
      continue;
    }

    if (token.type === "op") {
      if (token.value === ";;") {
        if (top()?.type !== "case" || top().phase !== "body") {
          fail("unexpected ;;");
          break;
        }
        closeSimple(";;");
        patternOpen = true;
        continue;
      }
      if (token.value === ")") {
        fail("unexpected )");
        break;
      }
      closeSimple(token.value);
      continue;
    }

    const keyword = current.length === 0 ? blockKeyword(token) : "";
    if (!keyword) {
      current.push(token);
      continue;
    }
    hasBlocks = true;
    if (keyword === "if") {
      stack.push({ type: "if", phase: "cond" });
    } else if (keyword === "then" || keyword === "elif" || keyword === "else" || keyword === "fi") {
      const expected = keyword === "then" ? ["cond"] : keyword === "elif" ? ["then"] : keyword === "else" ? ["then"] : ["then", "else"];
      if (top()?.type !== "if" || !expected.includes(top().phase)) {
        fail(`unexpected ${keyword}`);
        break;
      }
      if (keyword === "fi") stack.pop();
      else top().phase = keyword === "elif" ? "cond" : keyword;
    } else if (keyword === "for" || keyword === "while" || keyword === "until") {
      stack.push({ type: "loop", phase: "head" });
      if (keyword === "for") header = { variable: "", words: [], sawIn: false };
    } else if (keyword === "do" || keyword === "done") {
      if (top()?.type !== "loop" || top().phase !== (keyword === "do" ? "head" : "body")) {
        fail(`unexpected ${keyword}`);
        break;
      }
      if (keyword === "do") top().phase = "body";
      else stack.pop();
    } else if (keyword === "case") {
      stack.push({ type: "case", phase: "pattern" });
      subject = { word: null };
    } else if (keyword === "esac") {
      if (top()?.type !== "case") {
        fail("unexpected esac");
        break;
      }
      stack.pop();
    }
  }

  if (!error) {
    if (header || subject || patternOpen || stack.length > 0) fail("unclosed block construct");
    else if (current.length > 0) emit("command");
  }
  if (error) {
    const plain = splitProgram(tokens);
    return {
      ...plain,
      roles: plain.nodes.map(() => "command"),
      loopVariables: plain.nodes.map(() => ""),
      adjacency: plain.nodes.map(() => ({ before: "", after: "" })),
      hasBlocks,
      error,
    };
  }
  while (separators.length >= nodes.length && separators.at(-1) === "newline") separators.pop();
  return { nodes, separators, roles, loopVariables, adjacency, hasBlocks, error };
}

function isAssignment(value) {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(value);
}

function wordsInNode(tokens) {
  const words = [];
  let skipRedirectionTarget = false;
  for (const token of tokens) {
    if (token.type === "redir") {
      skipRedirectionTarget = !token.inlineTarget;
      continue;
    }
    if (skipRedirectionTarget && token.type === "word") {
      skipRedirectionTarget = false;
      continue;
    }
    if (token.type === "word") words.push(token);
  }
  return words;
}

const WRAPPER_OPTIONS = {
  command: { noArgument: new Set(["p", "v", "V"]), takesArgument: new Set() },
  env: { noArgument: new Set(["0", "i", "P", "v"]), takesArgument: new Set(["a", "C", "S", "u"]) },
  exec: { noArgument: new Set(["c", "l"]), takesArgument: new Set(["a"]) },
  nohup: { noArgument: new Set(), takesArgument: new Set() },
  builtin: { noArgument: new Set(), takesArgument: new Set() },
  sudo: { noArgument: new Set(["A", "B", "b", "E", "e", "H", "i", "K", "k", "l", "N", "n", "P", "S", "s", "v", "V"]), takesArgument: new Set(["C", "D", "g", "h", "p", "r", "R", "t", "T", "u", "U"]) },
  timeout: { noArgument: new Set(["f", "p", "v"]), takesArgument: new Set(["k", "s"]) },
};

const WRAPPER_LONG_OPTIONS = {
  command: { noArgument: new Set(["help", "version"]), takesArgument: new Set() },
  env: { noArgument: new Set(["ignore-environment", "null", "help", "version"]), takesArgument: new Set(["argv0", "block-signal", "chdir", "default-signal", "ignore-signal", "split-string", "unset"]) },
  exec: { noArgument: new Set(), takesArgument: new Set() },
  nohup: { noArgument: new Set(["help", "version"]), takesArgument: new Set() },
  builtin: { noArgument: new Set(), takesArgument: new Set() },
  sudo: { noArgument: new Set(["askpass", "background", "bell", "edit", "help", "login", "non-interactive", "preserve-env", "preserve-groups", "remove-timestamp", "reset-timestamp", "set-home", "shell", "stdin", "validate", "version"]), takesArgument: new Set(["chdir", "chroot", "close-from", "command-timeout", "group", "host", "other-user", "prompt", "role", "type", "user"]) },
  timeout: { noArgument: new Set(["foreground", "preserve-status", "verbose", "help", "version"]), takesArgument: new Set(["kill-after", "signal"]) },
};

function consumeWrapperOptions(name, words, index) {
  const optionOwner = name === "gtimeout" ? "timeout" : name;
  const short = WRAPPER_OPTIONS[optionOwner];
  const long = WRAPPER_LONG_OPTIONS[optionOwner];
  const embeddedPayloads = [];
  let next = index;
  while (words[next]) {
    const value = words[next].value;
    if (value === "--") return { index: next + 1, unresolved: false, embeddedPayloads };
    if (!value.startsWith("-") || value === "-") return { index: next, unresolved: false, embeddedPayloads };
    if (value.startsWith("--")) {
      const equals = value.indexOf("=");
      const option = value.slice(2, equals === -1 ? undefined : equals);
      if (long.noArgument.has(option)) {
        next += 1;
        continue;
      }
      if (!long.takesArgument.has(option)) return { index: next, unresolved: true, embeddedPayloads };
      if (equals !== -1) {
        if (name === "env" && option === "split-string") embeddedPayloads.push(value.slice(equals + 1));
        next += 1;
        continue;
      }
      if (!words[next + 1]) return { index: next, unresolved: true, embeddedPayloads };
      if (name === "env" && option === "split-string") embeddedPayloads.push(words[next + 1].value);
      next += 2;
      continue;
    }
    let consumedArgument = false;
    for (let offset = 1; offset < value.length; offset += 1) {
      const option = value[offset];
      if (short.noArgument.has(option)) continue;
      if (!short.takesArgument.has(option)) return { index: next, unresolved: true, embeddedPayloads };
      if (offset + 1 === value.length) {
        if (!words[next + 1]) return { index: next, unresolved: true, embeddedPayloads };
        if (name === "env" && option === "S") embeddedPayloads.push(words[next + 1].value);
        next += 2;
      } else {
        if (name === "env" && option === "S") embeddedPayloads.push(value.slice(offset + 1));
        next += 1;
      }
      consumedArgument = true;
      break;
    }
    if (!consumedArgument) next += 1;
  }
  return { index: next, unresolved: false, embeddedPayloads };
}

export function commandPosition(tokens) {
  const words = wordsInNode(tokens);
  let index = 0;
  while (index < words.length && isAssignment(words[index].value)) index += 1;
  const prefixAssignments = index;
  const wrappers = [];
  let unresolvedWrapperOption = false;
  const wrapperPayloads = [];
  let command = words[index];
  while (command) {
    const name = basename(command.value);
    // `builtin` is here because `builtin eval "$S"` is `eval "$S"`. Without it
    // the command word reads as `builtin` and everything that inspects a
    // command name - the kill rules, the rebinding list - looks past what runs.
    if (name === "exec" || name === "command" || name === "sudo" || name === "nohup" || name === "builtin") {
      wrappers.push(name);
      const options = consumeWrapperOptions(name, words, index + 1);
      unresolvedWrapperOption ||= options.unresolved;
      wrapperPayloads.push(...options.embeddedPayloads);
      index = options.index;
      command = words[index];
      continue;
    }
    if (name === "env") {
      wrappers.push(name);
      const options = consumeWrapperOptions(name, words, index + 1);
      unresolvedWrapperOption ||= options.unresolved;
      wrapperPayloads.push(...options.embeddedPayloads);
      index = options.index;
      while (words[index] && (words[index].value.startsWith("-") || isAssignment(words[index].value))) index += 1;
      command = words[index];
      continue;
    }
    if (name === "timeout" || name === "gtimeout") {
      wrappers.push(name);
      const options = consumeWrapperOptions(name, words, index + 1);
      unresolvedWrapperOption ||= options.unresolved;
      index = options.index;
      if (!words[index]) {
        unresolvedWrapperOption = true;
        command = undefined;
        break;
      }
      index += 1;
      command = words[index];
      if (!command) {
        unresolvedWrapperOption = true;
        break;
      }
      continue;
    }
    break;
  }
  return { words, index, command, wrappers, prefixAssignments, unresolvedWrapperOption, wrapperPayloads };
}

const PROTECTED_SCRIPTS = [
  { relative: "bin/fm-watch-arm.sh", kind: "arm" },
  { relative: "bin/fm-watch-checkpoint.sh", kind: "checkpoint" },
  { relative: "bin/fm-watch.sh", kind: "watch" },
];

function protectedIdentity(value, root) {
  const normalized = path.normalize(value);
  for (const { relative, kind } of PROTECTED_SCRIPTS) {
    if (normalized === relative || normalized === path.join(root, relative) || normalized.endsWith(`/${relative}`)) return kind;
  }
  return "";
}

function hasUnclassifiableProtectedExpansion(word, root) {
  if (!word?.unquotedExpansion || protectedIdentity(word.value, root)) return false;
  return /(?:^|\/)fm-watch/.test(word.value);
}

function shellInvocation(position) {
  if (!position.command) return null;
  const name = basename(position.command.value);
  if (!["sh", "bash", "zsh"].includes(name)) return null;
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const option = words[i];
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(option.value)) {
      let payloadIndex = i + 1;
      if (words[payloadIndex]?.value === "--") payloadIndex += 1;
      return { kind: "command", payload: words[payloadIndex] || null };
    }
    if (/^[-+]O$/.test(option.value)) {
      i += 1;
      continue;
    }
    if (option.value === "--" || /^[-+]/.test(option.value)) continue;
    return { kind: "script", payload: option };
  }
  return { kind: "stdin", payload: null };
}

function shellHeredocPayloads(tokens, position) {
  if (shellInvocation(position)?.kind !== "stdin") return [];
  const heredocs = tokens.filter((token) => token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string");
  return heredocs.length === 0 ? [] : [heredocs.at(-1).heredoc];
}

function shellHereStringPayloads(tokens, position) {
  if (shellInvocation(position)?.kind !== "stdin") return [];
  const payloads = [];
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.type !== "redir" || token.value !== "<<<" || token.fd !== 0) continue;
    const payload = tokens[i + 1];
    if (payload?.type === "word" && payload.literal && payload.subs.length === 0) payloads.push(payload.value);
  }
  return payloads;
}

function sourcedScript(position) {
  if (!position.command || ![".", "source"].includes(position.command.value)) return null;
  return position.words[position.index + 1] || null;
}

function evalPayload(position) {
  if (!position.command || basename(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

function wordReferencesAny(word, names) {
  if (!word || names.size === 0) return false;
  for (const match of word.value.matchAll(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g)) {
    if (names.has(match[1] || match[2])) return true;
  }
  return false;
}

function hasDynamicExecutionPayload(position, context) {
  if (!position.command) return false;
  const name = basename(position.command.value);
  if (["sh", "bash", "zsh"].includes(name)) {
    for (let i = position.index + 1; i < position.words.length; i += 1) {
      if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(position.words[i].value)) continue;
      const payload = position.words[i + 1];
      return Boolean(payload && (!payload.literal || payload.subs.length > 0) && wordReferencesAny(payload, context.protectedVariables));
    }
  }
  if (name === "eval") {
    return position.words.slice(position.index + 1).some((payload) => (!payload.literal || payload.subs.length > 0) && wordReferencesAny(payload, context.protectedVariables));
  }
  return false;
}

function assignmentName(word) {
  const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
  return match ? match[1] : "";
}

// A refusal control may only ever conclude that a name is possibly dangerous,
// never that it is safe. Dropping a binding when the name is reassigned reads
// the program as one straight line, which it is only until it branches or
// loops: a sibling `else` arm would clear a binding the taken arm made, and a
// loop body's later line runs before its earlier one on the second iteration.
// So in a program that contains blocks, taint accumulates and is never removed.
// Straight-line programs keep the previous last-writer-wins semantics exactly,
// which is why no non-block verdict moves.
function contextWithAssignments(context, words, monotone = false) {
  const protectedVariables = new Set(context.protectedVariables || []);
  const watcherPatterns = new Set(context.watcherPatterns || []);
  const watcherPids = new Set(context.watcherPids || []);
  for (const word of words) {
    const name = assignmentName(word);
    if (!name) continue;
    const value = word.value.slice(word.value.indexOf("=") + 1);
    if (rawMentionsProtected(value) || wordReferencesAny(word, protectedVariables)) protectedVariables.add(name);
    else if (!monotone) protectedVariables.delete(name);
    if (/fm-watch/.test(value) || wordReferencesAny(word, watcherPatterns)) watcherPatterns.add(name);
    else if (!monotone) watcherPatterns.delete(name);
    if (wordReferencesAny(word, watcherPids)) watcherPids.add(name);
    else if (!monotone) watcherPids.delete(name);
  }
  return { ...context, protectedVariables, watcherPatterns, watcherPids };
}

// A `for` loop variable takes its values from the header word list, so it earns
// the same watcher bindings contextWithAssignments would give it, including a
// pid binding from an executed watcher-wide pgrep in the list.
function bindLoopVariable(context, name, words, substitutionResults, monotone = false) {
  if (!name) return;
  const referencesProtected = words.some((word) => rawMentionsProtected(word.value) || wordReferencesAny(word, context.protectedVariables));
  const referencesPattern = words.some((word) => /fm-watch/.test(word.value) || wordReferencesAny(word, context.watcherPatterns));
  const referencesPid = words.some(
    (word) => wordReferencesAny(word, context.watcherPids) || word.subs.some((substitution) => substitutionResults.get(substitution)?.pgrepWatcher),
  );
  for (const [matched, names] of [
    [referencesProtected, context.protectedVariables],
    [referencesPattern, context.watcherPatterns],
    [referencesPid, context.watcherPids],
  ]) {
    if (matched) names.add(name);
    else if (!monotone) names.delete(name);
  }
}

// Names a command binds from input the parser does not model. `read` is the
// common one, and whatever feeds it - a pipeline into the loop, a redirection or
// process substitution attached to `done`, a here-string - is exactly what this
// parser does not follow. Over-collecting here only adds taint, so options and
// their values are not filtered out.
function readBoundNames(position) {
  if (basename(position.command?.value || "") !== "read") return [];
  return position.words
    .slice(position.index + 1)
    .filter((word) => word.literal && word.subs.length === 0 && /^[A-Za-z_][A-Za-z0-9_]*$/.test(word.value))
    .map((word) => word.value);
}

// A word's value holds its literal text but not the text of its command
// substitutions, so a purely syntactic pass has to ask for those separately.
// `P=$(pgrep -f fm-watch)` has the value `P=` and everything that matters in a
// substitution the seed never runs.
function wordSourceText(word, value) {
  if (word.subs.length === 0) return value;
  return `${value} ${word.subs.map((substitution) => substitution.content).join(" ")}`;
}

// Taint only grows, so the seed below settles in as many passes as the longest
// chain of one binding feeding the next. Two covers everything realistic; the
// limit bounds the cost on a pathological program, and not settling within it
// is reported so the caller can refuse rather than analyse a partial seed.
const SEED_PASS_LIMIT = 4;

// Every assignment in a block program is in effect everywhere in it: an `if`
// arm's binding outlives the construct whatever the sibling arms do, and a loop
// body's last line has already run by the time its first line runs again. This
// is the unordered-set reading of that, repeated because one binding can feed
// the next, and seeded into the analysis so a use that textually precedes its
// definition still sees it.
//
// It is deliberately syntactic: it never runs the nested analysis, so it cannot
// tell `P=$(pgrep -f fm-watch)` from any other substitution naming a watcher and
// taints both. Unknown counts as tainted, never as safe.
function seedBlockTaint(program, context, command) {
  const protectedVariables = new Set(context.protectedVariables || []);
  const watcherPatterns = new Set(context.watcherPatterns || []);
  const watcherPids = new Set(context.watcherPids || []);
  // A name read from unmodelled input holds an unknown value. That only has to
  // count as a watcher value when the program names a watcher somewhere; an
  // ordinary `while read -r p; do kill $p; done` over unrelated pids is not
  // this control's business.
  const unknownIsWatcher = /fm-watch/.test(normalizeLineContinuations(command));
  const positions = program.nodes.map((tokens) => commandPosition(tokens));
  const size = () => protectedVariables.size + watcherPatterns.size + watcherPids.size;
  let converged = false;
  for (let pass = 0; pass < SEED_PASS_LIMIT && !converged; pass += 1) {
    const before = size();
    for (let nodeIndex = 0; nodeIndex < program.nodes.length; nodeIndex += 1) {
      if (program.roles?.[nodeIndex] === "for-list") {
        const name = program.loopVariables[nodeIndex];
        if (!name) continue;
        const words = program.nodes[nodeIndex]
          .filter((token) => token.type === "word")
          .map((word) => ({ word, text: wordSourceText(word, word.value) }));
        if (words.some(({ word, text }) => rawMentionsProtected(text) || wordReferencesAny(word, protectedVariables))) protectedVariables.add(name);
        if (words.some(({ word, text }) => /fm-watch/.test(text) || wordReferencesAny(word, watcherPatterns))) watcherPatterns.add(name);
        if (words.some(({ word, text }) => wordReferencesAny(word, watcherPids) || (/fm-watch/.test(text) && word.subs.length > 0))) watcherPids.add(name);
        continue;
      }
      const position = positions[nodeIndex];
      for (const word of position.words) {
        const name = assignmentName(word);
        if (!name) continue;
        const text = wordSourceText(word, word.value.slice(word.value.indexOf("=") + 1));
        if (rawMentionsProtected(text) || wordReferencesAny(word, protectedVariables)) protectedVariables.add(name);
        if (/fm-watch/.test(text) || wordReferencesAny(word, watcherPatterns)) watcherPatterns.add(name);
        if (wordReferencesAny(word, watcherPids) || (/fm-watch/.test(text) && word.subs.length > 0)) watcherPids.add(name);
      }
      if (!unknownIsWatcher) continue;
      for (const name of readBoundNames(position)) {
        protectedVariables.add(name);
        watcherPatterns.add(name);
        watcherPids.add(name);
      }
    }
    converged = size() === before;
  }
  return { protectedVariables, watcherPatterns, watcherPids, converged };
}

// Commands whose standard input the parser is confident is read and nothing
// else: each copies, counts, filters or digests its input, and none of them
// interprets any of it as a program or writes it anywhere it could be run.
//
// This is an allowlist rather than a list of consumers that execute what they
// are handed, and the direction matters. The executing ones are unbounded -
// every shell, every interpreter, `ssh host`, `at now`, `xargs sh -c` - so a
// name missing from a list of those would be a permit. A name missing from this
// list is only friction: its body stays in view and the command is refused
// inside a construct. It was a blocklist of three shell names until it was
// found to admit thirty others.
//
// Membership here is necessary and not sufficient. It answers only "does this
// command execute what it reads", which is the smaller half of the question:
// the shell expands an unquoted here-document body before this command is
// reached at all, so the delimiter has to be quoted as well.
//
// `sed` and `awk` are absent because `-f -` makes the input a program, `tee`
// and `dd` because they write it to a file, and every interpreter because
// running its input is what it is for. Their bodies stay in view.
//
// `sort` and `uniq` are absent for the same reason as `tee`, which is easy to
// miss because neither looks like a writer: `sort -o FILE` and `uniq - FILE`
// both take an output file as an ordinary argument, with no shell redirection
// for the redirection rule to catch. A name earns a place here by having no way
// at all to put its input somewhere it can be run later, not by usually not
// doing so.
const INPUT_READER_COMMANDS = new Set([
  "cat", "head", "tail", "wc", "nl", "rev", "tr", "cut", "fold",
  "grep", "egrep", "fgrep", "cksum", "md5sum", "sha1sum", "sha256sum", "sha512sum", "base64",
]);

// Commands that change what a name resolves to. Every entry in the list above
// is the command it spells only while nothing has rebound it, and an alias, a
// disabled builtin, a hashed path, a sourced file, or a string kept to be
// evaluated later all rebind it silently. The parser cannot follow any of
// those, so their presence anywhere in the program withdraws the allowlist
// rather than being reasoned around.
//
// This one is a blocklist, unavoidably, but over a closed and small domain -
// the shell's own name-resolution builtins - rather than over every program on
// the machine that might execute an argument. Membership is by that rule alone:
// `export`, `declare`, `set` and `shopt` are absent because none of them can
// give a name a new meaning, and a program that sets a variable or a shell
// option keeps reading its quoted text as text.
const NAME_REBINDING_COMMANDS = new Set(["alias", "unalias", "enable", "hash", "eval", "source", ".", "trap"]);

// Whether this program does anything that could make a command name mean
// something other than the name it spells: a function definition, one of the
// commands above, or a new PATH, seen wherever the assignment sits - on its
// own, as a prefix, or as an argument to `export`.
//
// PATH matters because the reader allowlist's members are all external
// programs, so `PATH+=` counts exactly as `PATH=` does.
//
// A group is searched rather than assumed guilty. `(date)` and `{ date; }`
// rebind nothing, and reading their contents with the same lexer costs one pass
// and keeps ordinary programs out of the raw check. A group that cannot be read
// counts as rebinding, like every other thing the parser cannot see. A
// subshell's bindings would die with it, but it is searched like a brace group
// rather than scoped, because refusing `(alias echo=eval)` costs nothing.
function programRebindsNames(program, depth = 0) {
  if (depth > 12) return true;
  for (const tokens of program.nodes) {
    for (let index = 0; index < tokens.length; index += 1) {
      const token = tokens[index];
      if (token.type === "word" && /^PATH\+?=/.test(token.value)) return true;
      if (token.type !== "group") continue;
      // `name()` - an empty subshell after a word is a function definition and
      // is never anything else, since `( )` alone is not a command.
      if (token.kind === "subshell" && token.content.trim() === "" && tokens[index - 1]?.type === "word") return true;
      if (groupRebindsNames(token, depth)) return true;
    }
    const position = commandPosition(tokens);
    if (!position.command) continue;
    // A command word the parser cannot read is not a name it can clear: `$C`
    // expands to `source` as easily as to anything else.
    if (!position.command.literal || position.command.subs.length > 0) return true;
    if (NAME_REBINDING_COMMANDS.has(basename(position.command.value))) return true;
  }
  return false;
}

function groupRebindsNames(group, depth) {
  const lexed = new Lexer(group.content, { blocks: true }).tokenize();
  if (lexed.error) return true;
  const program = splitBlockProgram(lexed.tokens);
  if (program.error) return true;
  return programRebindsNames(program, depth + 1);
}

// Here-document bodies this node holds that no part of the program can run.
//
// Two independent things have to be true, because two different things can run
// a body. The shell expands an unquoted body - parameter, command and
// arithmetic expansion - while setting the here-document up, before the reading
// command is reached, so `cat <<EOF` holding `$(pkill ...)` runs that kill and
// `cat` never sees it happen. Only a quoted delimiter, `<<'EOF'` or `<<"EOF"`,
// makes the body literal, and that is a property of the text rather than a
// belief about a program. Then the command itself has to be one that reads its
// input and nothing else, or `bash <<'EOF'` would run the literal text.
//
// The node must also not hand what it holds to anything else: `cat <<EOF`
// prints its body, but `cat <<EOF | bash` runs it, `cat <<EOF > f` stores it
// for later, and a body attached to `done` goes wherever the loop sends its
// input, which is not modelled.
//
// The command must be a bare name with no wrapper in front of it, because the
// allowlist names specific commands and neither `/tmp/x/cat` nor `env cat` is
// the command it spells: the first is whatever sits at that path, and `env`,
// `exec`, `nohup`, `timeout` and `sudo` all run the external program rather
// than the builtin. `command` and `builtin` do resolve to the builtin, but they
// are excluded with the rest rather than carved out, because a list whose entry
// needs an exception is how this went wrong before.
//
// Anything short of a positive answer to all of it leaves the bytes in the text.
function dataHeredocRanges(tokens, adjacent) {
  const position = commandPosition(tokens);
  if (!position.command || !position.command.literal || position.command.subs.length > 0) return [];
  if (position.wrappers.length > 0 || position.command.value.includes("/")) return [];
  if (!INPUT_READER_COMMANDS.has(position.command.value)) return [];
  for (const side of [adjacent?.before, adjacent?.after]) {
    if (side === "|" || side === "|&") return [];
  }
  if (!tokens.every((token) => token.type !== "redir" || (Array.isArray(token.heredocRange) && token.heredocQuoted === true))) return [];
  return tokens.filter((token) => token.type === "redir" && Array.isArray(token.heredocRange)).map((token) => token.heredocRange);
}

// The part of the program that actually runs: the whole command with the text
// nothing in it can run cut out. That is comments, which run nowhere at all,
// and here-document bodies the shell is required to leave literal and hands to
// a command that only reads them.
//
// Quoted argument text is deliberately not cut. A quoted run is inert to the
// shell in the same way a quoted here-document body is, so an argument half of
// this cut can be argued for on the same footing; it is left out because the
// case for each new inert-looking shape has twice turned out to be narrower
// than it read, and the whole relaxation is worth less than the certainty.
//
// This is not a quote-aware or here-document-aware regex, which would be a
// cleverer version of the thing it is backing up. The lexer already established
// which bytes are commented, which body belongs to which command, and whether
// its delimiter was quoted; the unchanged raw check simply reads what is left.
function executableProgramText(command, program, comments) {
  const ranges = [...comments];
  // The cut reads a command name and concludes something about bytes from it,
  // so a program that can give a name a new meaning takes the claim away.
  // Comments survive it: they are not a claim about any command.
  const namesAreTrustworthy = !programRebindsNames(program);
  for (let nodeIndex = 0; namesAreTrustworthy && nodeIndex < program.nodes.length; nodeIndex += 1) {
    const tokens = program.nodes[nodeIndex];
    const adjacent = program.adjacency?.[nodeIndex];
    for (const range of dataHeredocRanges(tokens, adjacent)) ranges.push(range);
  }
  if (ranges.length === 0) return command;
  ranges.sort((left, right) => left[0] - right[0]);
  let text = "";
  let cursor = 0;
  for (const [start, end] of ranges) {
    if (start < cursor) continue;
    text += command.slice(cursor, start);
    cursor = end;
  }
  return text + command.slice(cursor);
}

function nodeHasRedirection(tokens) {
  return tokens.some((token) => token.type === "redir");
}

function nodeHasUnsafeSubstitution(tokens) {
  return tokens.some((token) => token.type === "word" && token.subs.length > 0);
}

function isWatcherPgrep(position, context) {
  if (!position.command || basename(position.command.value) !== "pgrep") return false;
  return position.words.slice(position.index + 1).some((word) => /(?:^|\/)fm-watch(?:\.sh)?\b/.test(word.value) || wordReferencesAny(word, context.watcherPatterns));
}

function analyzeProgram(command, context, depth = 0) {
  if (depth > 12) {
    return { error: "recursion limit", protectedFound: rawMentionsProtected(command), broadKill: rawMentionsBroadKill(command), pgrepWatcher: false, watcherPids: new Set() };
  }
  const lexed = new Lexer(command, { blocks: true }).tokenize();
  if (lexed.error) {
    return { error: lexed.error, protectedFound: rawMentionsProtected(command), broadKill: rawMentionsBroadKill(command), pgrepWatcher: false, watcherPids: new Set() };
  }
  const program = splitBlockProgram(lexed.tokens);
  const nodeInfos = [];
  let nestedProtected = false;
  let broadKill = false;
  let pgrepWatcher = false;
  let unsupported = false;
  let activeContext = {
    ...context,
    protectedVariables: new Set(context.protectedVariables || []),
    watcherPatterns: new Set(context.watcherPatterns || []),
    watcherPids: new Set(context.watcherPids || []),
  };
  let unclassifiableProtected = false;
  // Block syntax the scanner could not fit into a well-formed construct keeps
  // the whole program on the conservative path, raw fallback included.
  if (program.error) unsupported = true;
  // Branching and looping make the running context a may-analysis: bindings
  // accumulate, and the ones the whole program can produce are in force from
  // its first line.
  const monotone = program.hasBlocks && !program.error;
  if (monotone) {
    const seed = seedBlockTaint(program, activeContext, command);
    activeContext = { ...activeContext, protectedVariables: seed.protectedVariables, watcherPatterns: seed.watcherPatterns, watcherPids: seed.watcherPids };
    if (!seed.converged) unsupported = true;
  }

  for (let nodeIndex = 0; nodeIndex < program.nodes.length; nodeIndex += 1) {
    const tokens = program.nodes[nodeIndex];
    const forList = program.roles?.[nodeIndex] === "for-list";
    const position = commandPosition(tokens);
    // A `for` header carries no assignment, so it inherits the running context
    // unchanged and contributes only its loop-variable binding below.
    const nodeContext = forList
      ? { ...activeContext, protectedVariables: new Set(activeContext.protectedVariables), watcherPatterns: new Set(activeContext.watcherPatterns), watcherPids: new Set(activeContext.watcherPids) }
      : contextWithAssignments(activeContext, position.words, monotone);
    const firstName = basename(position.words[0]?.value || "");
    if (["if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac", "do", "done", "function", "time", "coproc"].includes(firstName)) {
      unsupported = true;
    }

    let nodeNestedProtected = false;
    let nodePgrepWatcher = false;
    const substitutionResults = new Map();
    for (const payload of position.wrapperPayloads) {
      const nested = analyzeProgram(payload, nodeContext, depth + 1);
      nodeNestedProtected ||= nested.protectedFound;
      broadKill ||= nested.broadKill;
      nodePgrepWatcher ||= nested.pgrepWatcher;
      if (nested.error && rawMentionsProtected(payload)) unsupported = true;
    }
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = analyzeProgram(token.content, nodeContext, depth + 1);
        nodeNestedProtected ||= nested.protectedFound;
        broadKill ||= nested.broadKill;
        nodePgrepWatcher ||= nested.pgrepWatcher;
        if (nested.error && rawMentionsProtected(token.content)) unsupported = true;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = analyzeProgram(substitution.content, nodeContext, depth + 1);
          substitutionResults.set(substitution, nested);
          nodeNestedProtected ||= nested.protectedFound;
          broadKill ||= nested.broadKill;
          nodePgrepWatcher ||= nested.pgrepWatcher;
          if (nested.error && rawMentionsProtected(substitution.content)) unsupported = true;
        }
      }
    }

    if (forList) {
      bindLoopVariable(nodeContext, program.loopVariables[nodeIndex], position.words, substitutionResults, monotone);
      pgrepWatcher ||= nodePgrepWatcher;
      nestedProtected ||= nodeNestedProtected;
      activeContext = nodeContext;
      continue;
    }

    const shell = shellInvocation(position);
    const shellPayload = shell?.kind === "command" ? shell.payload : null;
    const shellScript = shell?.kind === "script" ? shell.payload : null;
    const sourceScript = sourcedScript(position);
    const literalEvalPayload = evalPayload(position);
    const heredocPayloads = shellHeredocPayloads(tokens, position);
    const hereStringPayloads = shellHereStringPayloads(tokens, position);
    for (const script of [shellScript, sourceScript]) {
      if (!script) continue;
      nodeNestedProtected ||= Boolean(protectedIdentity(script.value, context.root)) || wordReferencesAny(script, nodeContext.protectedVariables);
      unclassifiableProtected ||= hasUnclassifiableProtectedExpansion(script, context.root);
    }
    if (shellPayload && (!shellPayload.literal || shellPayload.subs.length > 0)) {
      if (wordReferencesAny(shellPayload, nodeContext.protectedVariables)) nodeNestedProtected = true;
    } else if (shellPayload) {
      const nested = analyzeProgram(shellPayload.value, nodeContext, depth + 1);
      nodeNestedProtected ||= nested.protectedFound;
      broadKill ||= nested.broadKill;
      nodePgrepWatcher ||= nested.pgrepWatcher;
      if (nested.error && rawMentionsProtected(shellPayload.value)) unsupported = true;
    }
    for (const payload of [literalEvalPayload, ...heredocPayloads, ...hereStringPayloads]) {
      if (payload === null) continue;
      const nested = analyzeProgram(payload, nodeContext, depth + 1);
      nodeNestedProtected ||= nested.protectedFound;
      broadKill ||= nested.broadKill;
      nodePgrepWatcher ||= nested.pgrepWatcher;
      if (nested.error && rawMentionsProtected(payload)) unsupported = true;
    }

    const executable = position.command?.value || "";
    const protectedKind = protectedIdentity(executable, context.root);
    if (hasUnclassifiableProtectedExpansion(position.command, context.root)) unclassifiableProtected = true;
    const commandName = basename(executable);
    const args = position.words.slice(position.index + 1);
    if (commandName === "pkill" && args.some((word) => /fm-watch/.test(word.value) || wordReferencesAny(word, nodeContext.watcherPatterns))) broadKill = true;
    if (commandName === "kill" && (nodePgrepWatcher || args.some((word) => wordReferencesAny(word, nodeContext.watcherPids)))) broadKill = true;
    if (isWatcherPgrep(position, nodeContext)) pgrepWatcher = true;
    if (hasDynamicExecutionPayload(position, nodeContext) || wordReferencesAny(position.command, nodeContext.protectedVariables)) nodeNestedProtected = true;
    for (const word of position.words) {
      const name = assignmentName(word);
      if (!name) continue;
      if (word.subs.some((substitution) => substitutionResults.get(substitution)?.pgrepWatcher)) nodeContext.watcherPids.add(name);
    }
    pgrepWatcher ||= nodePgrepWatcher;
    nestedProtected ||= nodeNestedProtected;
    activeContext = nodeContext;
    if (position.unresolvedWrapperOption) unsupported = true;
    nodeInfos.push({
      tokens,
      position,
      protectedKind,
      nestedProtected: nodeNestedProtected,
      redirection: nodeHasRedirection(tokens),
      substitution: nodeHasUnsafeSubstitution(tokens),
    });
  }

  const directProtected = nodeInfos.some((info) => Boolean(info.protectedKind));
  let protectedFound = directProtected || nestedProtected || unclassifiableProtected;
  if (unclassifiableProtected) unsupported = true;
  // A block construct can never be a blessed arm: arming is a standalone final
  // command after approved setup nodes, so a protected execution reached
  // through a condition, loop body, or case arm stays unclassifiable.
  if (program.hasBlocks && protectedFound) unsupported = true;
  // Second layer. Parsing a construct is not understanding it: this model will
  // keep meeting data flow it does not represent, and until now the raw check
  // only ran on the unsupported path, so a block that parsed cleanly bought a
  // permit no straight-line program could. Give a parsed block program the same
  // unchanged check over the part of it that runs.
  //
  // What that leaves out has to be text the shell cannot run rather than text
  // the model believes is harmless, or this layer is backing up the model with
  // the model. An unquoted here-document body once qualified on the second
  // reading and expanded on the first, and the substitutions in it were gone
  // from the scan before it ran.
  const rawChecked = unsupported || program.hasBlocks;
  const scanned = unsupported || program.error ? command : executableProgramText(command, program, lexed.comments);
  const broadKillFound = broadKill || (rawChecked && rawMentionsBroadKill(scanned));
  if (rawChecked && rawMentionsProtected(scanned)) {
    protectedFound = true;
    unsupported = true;
  }
  if (unsupported && (protectedFound || rawMentionsProtected(command) || broadKillFound)) {
    return { error: "unsupported compound grammar", protectedFound: true, broadKill: broadKillFound, pgrepWatcher, watcherPids: activeContext.watcherPids, program, nodeInfos };
  }
  return { error: "", protectedFound, directProtected, nestedProtected, broadKill: broadKillFound, pgrepWatcher, watcherPids: activeContext.watcherPids, program, nodeInfos };
}

function xModePathAllowed(value, home) {
  if (value === "config/x-mode.env" || value === "./config/x-mode.env") return true;
  if (!path.isAbsolute(value)) return false;
  return path.normalize(value) === path.join(path.normalize(home), "config/x-mode.env");
}

function ordinaryWordsOnly(tokens) {
  return tokens.every((token) => token.type === "word" && token.subs.length === 0);
}

function setupKind(info, context) {
  const { tokens, position } = info;
  if (!ordinaryWordsOnly(tokens) || position.prefixAssignments > 0 || position.wrappers.length > 0) return "";
  const values = position.words.map((word) => word.value);
  if (values[0] === "cd" && values.length === 2) return "cd";
  if (values[0] === "export" && values.length === 2 && isAssignment(values[1])) return "export";
  if ((values[0] === "source" || values[0] === ".") && values.length === 2 && xModePathAllowed(values[1], context.home)) return "source";
  if (values[0] === "[" && values[1] === "-f" && values[3] === "]" && values.length === 4 && xModePathAllowed(values[2], context.home)) return "test-source";
  return "";
}

function finalProtectedAllowed(info) {
  if (!info.protectedKind || info.protectedKind === "watch" || info.redirection || info.substitution) return false;
  if (!ordinaryWordsOnly(info.tokens) || info.position.prefixAssignments > 0) return false;
  const wrappers = info.position.wrappers;
  return wrappers.length === 0 || (wrappers.length === 1 && wrappers[0] === "exec");
}

function blessedProgram(analysis, context) {
  const { nodeInfos } = analysis;
  const separators = analysis.program.separators;
  if (nodeInfos.length === 0 || separators.some((separator) => ![";", "newline", "&&"].includes(separator))) return false;
  if (!finalProtectedAllowed(nodeInfos.at(-1))) return false;
  if (nodeInfos.slice(0, -1).some((info) => info.protectedKind || info.nestedProtected)) return false;

  const setup = nodeInfos.slice(0, -1).map((info) => setupKind(info, context));
  if (setup.some((kind) => !kind)) return false;
  for (let i = 0; i < setup.length; i += 1) {
    if (setup[i] !== "test-source") continue;
    if (setup[i + 1] !== "source" || separators[i] !== "&&") return false;
    i += 1;
  }
  return true;
}

function decision(command, root, home) {
  const context = { root: path.normalize(root), home: path.normalize(home), protectedVariables: new Set(), watcherPatterns: new Set(), watcherPids: new Set() };
  const analysis = analyzeProgram(command, context);
  if (analysis.broadKill) return deny("broad-watcher-kill");
  if (analysis.error && analysis.protectedFound) return deny("unclassifiable-protected-command");
  if (!analysis.protectedFound) return { decision: "allow" };
  if (analysis.nodeInfos?.some((info) => info.protectedKind === "watch")) return deny("watcher-direct");
  if (analysis.nestedProtected) return deny("watcher-nested");

  const separators = analysis.program.separators;
  if (separators.includes("&") || analysis.nodeInfos.some((info) => info.position.wrappers.includes("nohup")) || analysis.nodeInfos.some((info) => basename(info.position.words[0]?.value || "") === "disown")) {
    return deny("watcher-background");
  }
  if (separators.includes("|") || separators.includes("|&")) return deny("watcher-pipeline");
  if (analysis.nodeInfos.some((info) => info.redirection)) return deny("watcher-redirection");
  if (analysis.nodeInfos.some((info) => info.substitution)) return deny("watcher-nested");
  if (blessedProgram(analysis, context)) return { decision: "allow" };
  if (analysis.nodeInfos.some((info) => info.position.prefixAssignments > 0 || info.position.wrappers.some((wrapper) => wrapper !== "exec"))) {
    return deny("watcher-nested");
  }
  return deny("watcher-bundled");
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

// Run the CLI only when invoked directly (node fm-arm-command-policy.mjs ...),
// never when imported by a sibling policy such as bin/fm-cd-command-policy.mjs.
function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.root || !args.home) throw new Error("--root and --home are required");
    if (!args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.root, args.home);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
