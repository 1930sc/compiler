= Parsing =

A computer program is usually stored as a string intended for human
consumption.In contrast, language specifications usually concentrate on an
abstract representation, such as a syntax tree, where we can ignore details
such as which characters count as whitespace.

A parser is a function taking a string to its corresponding syntax tree, or an
error if the string is not a valid program.

------------------------------------------------------------------------------
parse :: [Char] -> Either Error Language
------------------------------------------------------------------------------

Sometimes parsing is broken into more steps. A lexer tries to turn a string
into a list of tokens, which the parser tries to turn into program.

------------------------------------------------------------------------------
lex :: [Char] -> Either Error [Token]
parse :: [Token] -> Either Error Language
------------------------------------------------------------------------------

Parsing is often viewed as part of the compiler's job, so a better
definition of `compile` may be:

------------------------------------------------------------------------------
compile :: [Char] -> Either Error TargetLanguage
------------------------------------------------------------------------------

In general we may also need to transform a program in `TargetLanguage` to some
binary format. For the ION machine, we'll define a sort of assembly language
that will be our `TargetLanguage`.

\begin{code}
{-# LANGUAGE NamedFieldPuns #-}
import Control.Monad
import Data.Char (ord)
import System.Environment
import Text.Megaparsec
import Text.Megaparsec.Char
import ION
\end{code}

== ION assembly ==

We define a language that is easy to generate and parse, and that humans can
tolerate in small doses:

------------------------------------------------------------------------------
digit = '0' | ... | '9'
num = digit [num]
con = '#' CHAR | '(' num ')'
idx = '@' CHAR | '[' num ']'
comb = 'S' | 'K' | 'I' | ...
term = comb | '`' term term | con | idx
prog = term ';' [prog]
------------------------------------------------------------------------------

A program is a sequence of terms terminated by semicolons.
The entry point is the last term of the sequence.

The motivation for supporing a sequence instead of insisting on a single term
is that instead of writing programs of the form:

------------------------------------------------------------------------------
norm = (\sq x y -> sq x + sq y) (\x -> x * x)
------------------------------------------------------------------------------

we can write:

------------------------------------------------------------------------------
square x = x * x
norm x y = square x + square y
------------------------------------------------------------------------------

The semicolon terminators are unnecessary, but greatly aid human
comprehension.

The backquote is a prefix binary operator denoting application.
For example, we represent the program `BS(BB)` with:

------------------------------------------------------------------------------
``BS`BB;
------------------------------------------------------------------------------

A term is represented by the last element of a sequence of expressions
terminated by semicolons. The sequence is 0-indexed, and we may refer to an
earlier term by enclosing its index in square brackets.

Thus another way to represent `BS(BB)` is:

------------------------------------------------------------------------------
B;``[0]S`[0][0];
------------------------------------------------------------------------------

An term may refer to an earlier term using the `(@)` prefix unary
operator. Let `n` be the ASCII code of the character following `(@)`. Then
it refers to the term of index `n - 32`. This offset is chosen so that short
programs can be written in printable ASCII without worrying about decimal
conversion.

For example, instead of `[0]` we may write `@ ` and instead of `[10]` we may
write `@*`.

If an earlier term is needed multiple times, then we share it rather than
duplicate it. Accordingly, we define combinatory logic terms to be combinators,
applications, and indexes of previously defined terms:

\begin{code}
data CL = Com Int | CL :@ CL | Nat Int | Idx Int
\end{code}

An 32-bit word constant is represented by a number in parentheses. For example,
42 is represented by `(42)`.

An alternative representation is to use the unary prefix operator `(#)`, in
which case the constant is the ASCII code of the following character.  Again,
this allows us to generate programs without dealing about decimal conversion.

For example, instead of `(42)` we may write `#*`.

== Parser ==

We use Megaparsec to build a recursive descent parser for our language.

\begin{code}
digit = oneOf ['0'..'9']
num = read <$> some digit
nat = ord <$> (char '#' *> anySingle)
  <|> char '(' *> num <* char ')'
idx = (+(-32)) . ord <$> (char '@' *> anySingle)
  <|> char '[' *> num <* char ']'
comb = Com . ord <$> oneOf "SKIBCTRY:L=+-/*%?"
term = comb
  <|> ((:@) <$> (char '`' *> term) <*> term)
  <|> Nat <$> nat
  <|> Idx <$> idx

prog :: Parsec () String [CL]
prog = some (term <* char ';')
\end{code}

We serialize terms as follows.

\begin{code}
fromExpr :: [(Int, Int)] -> CL -> VM -> (Int, VM)
fromExpr defs t vm = case t of
  Com n -> (n, vm)
  x :@ y -> let
    (a, vm1) = fromExpr defs x vm
    (b, vm2) = fromExpr defs y vm1
    in app a b vm2
  Nat n -> app 35 n vm
  Idx n | Just addr <- lookup n defs -> (addr, vm)

fromProg :: [CL] -> VM -> VM
fromProg ts vm = push root vm1 where
  ((_, root):_, vm1) = foldl addDef ([], vm) ts
  addDef (defs, m) t = let (addr, m') = fromExpr defs t m
    in ((length defs, addr):defs, m')
\end{code}

We add a helper to add custom combinators to a given program so it takes
standard input and writes to standard output.

\begin{code}
wrapIO :: CL -> CL
wrapIO x = x :@ (Com 48 :@ Com 63) :@ Com 46 :@ (Com 84 :@ Com 49)
\end{code}

Lastly, a `main` function which runs the program in the file whose name is
supplied as the first argument:

\begin{code}
main :: IO ()
main = getArgs >>= \as -> case as of
  []  -> putStrLn "Must provide program."
  [f] -> do
    s <- readFile f
    case parse prog "" s of
      Left err -> putStrLn $ "Parse error: " <> show err
      Right cls -> do
        void $ evalIO $ fromProg (cls ++ [wrapIO $ Idx $ length cls - 1]) new
  _   -> putStrLn "One program only."
\end{code}

For example:

------------------------------------------------------------------------------
$ echo -n 'I;' > id
$ echo "Hello" | ion id
Hello
$ echo -n '``C`T?`KI;' > tail
$ echo "tail" | ion tail
ail
------------------------------------------------------------------------------
