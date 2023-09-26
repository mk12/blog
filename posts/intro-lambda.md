---
title: Introduction to the λ-calculus
subtitle: Meet your new favourite formal system
category: Math
date: 2015-04-07T12:48:12-04:00
---

Most people think of Newton and Leibniz's infinitesimal calculus when they hear the word <dfn>calculus</dfn>, but the term is actually more general than that. A calculus is a formal system of calculation or reasoning, usually involving the symbolic manipulation of expressions. The λ-calculus (<dfn>lambda calculus</dfn>) is one such system, and it is very important in computer science.

# Expressions

Everything in the λ-calculus is an expression. There are three types of expressions: variables, abstractions, and applications:

1. A <dfn>variable</dfn> is represented by a letter such as $x$. The letter has no purpose other than to distinguish one variable from another.
2. An <dfn>abstraction</dfn> has the form $λx.e$ where $x$ must be a variable and $e$ can be any expression. You can think of it as an anonymous function of one parameter $x$ with a function body $e$.
3. An <dfn>application</dfn> has the form $hx$ where $h$ and $x$ are expressions. If $h$ is an abstraction, then this is like applying a function $h$ to an argument $x$.

Using this recursive definition, we can tell whether any string of characters is a valid λ-expression. For example, $λx.λ$ is invalid because the part after the abstraction's period should be an expression, but λ by itself is not an expression. On the other hand, $λa.λb.λc.c$ is a well-formed expression.

To interpret λ-expressions unambiguously, we need a few conventions:

- Outer parentheses are unnecessary: $(((x)))$ is the same as $x$.
- Applications are left-associative: $((ab)c)$ is the same as $abc$. On the other hand, the parentheses in $a(bc)$ are necessary to preserve meaning.
- Abstraction bodies extend as far to the right as possible: $λx.(xx)$ is the same as $λx.xx$, which is different from the application $(λx.x)x$.

# Free variables

When we look at all the variables in a given λ-expression, we classify some as <dfn>free variables</dfn>. A variable by itself, such as $x$, is always a free variable. However, the $x$ in $λx.x$ is not free because the abstraction <dfn>binds</dfn> it; we call these variables <dfn>bound variables</dfn>. All variables are free until they are bound in an enclosing abstraction. Let's look at some examples:

| Expression | Free variables |
| -----------| -------------- |
| $x$        | $x$            |
| $λx.xx$    |                |
| $λx.y$     | $y$            |
| $λy.λx.y$  |                |
| $a(bc)d$   | $a,b,c,d$      |
| $(λa.ab)a$ | $a,b$          |

Be careful with that last example. Clearly $b$ is a free variable, but what about $a$? It looks like $a$ occurs three times, but there are actually two distinct variables here! The $a$ that occurs in the abstraction is a bound variable, while the rightmost $a$ is a free variable. When a variable is bound, everything inside the abstraction refers to this new bound variable, regardless of what the variable means outside. In these cases, we say that the new bound variable <dfn>shadows</dfn> the free variable. To drive the point home, consider the expression $aλa.(aλa.(aλa.a))$. Here we have four distinct variables -- one free and three bound -- and they all reuse the letter $a$.

One final thing to note is that a variable's freedom depends on the scope being considered. If we consider $λx.bx$ as a whole, then $x$ is a bound variable. Even so, it is equally correct to say that $x$ is a free variable in $bx$ of that expression. For this reason, we should always be clear if we are talking about the whole expression or just a part of it.

# Reduction

The heart of the lambda calculus lies in the reduction of expressions. Reduction is a process guided by a set of simple yet powerful rules, and it is the essential component that allows us to call the λ-calculus a calculus. There are three methods of reducing expressions, named using the Greek letters alpha, beta, and eta.

Alpha-reduction allows us to rename parameters in abstractions. We do this by changing the parameter, including and all its occurrences in the body, to a new letter. For example, $λx.x$ is alpha-equivalent to $λn.n$. The parameter is just a placeholder -- it's name doesn't really matter. However, there are two restrictions on alpha-reduction. First, the new variable must not occur as a free variable in the body. Consider $λa.ab$, an abstraction that applies its argument to $b$. If we rename $a$ to $b$, we get $λb.bb$, an abstraction that applies its argument to itself -- something went wrong here! This new expression has a different meaning because we inadvertently captured the free variable $b$, making it a bound variable. Second, the old variable must not occur in an abstraction where the new variable is already bound. Consider $λa.λb.a$; if we rename $a$ to $b$, we get $λb.λb.b$, which is different because $b$ now refers to the inner bound variable rather than the outer one. As long as we avoid these two cases, alpha-reduction always results in expressions that intuitively have the same meaning.

Beta-reduction is what really makes things happen. It only works on applications of abstractions, and you can think of it as function application. An expression of the form $(λx.e)a$ beta-reduces to $e[a/x]$, which denotes $e$ with $a$ substituted for all occurrences of $x$ in a special way called capture-avoiding substitution. For example, $(λx.xx)u$ is beta-equivalent to $uu$. However, it is not so straightforward to reduce $(λx.λy.x)y$ because it should be an abstraction that always returns the free variable $y$, but simple substitution yields $λy.y$, which returns the bound variable $y$ instead! We avoid this problem using capture-avoiding substitution:

- $x[a/x] = a$, just like simple substitution.
- $y[a/x] = y$ if $x\ne y$, also like simple substitution.
- $(h n)[a/x] = (h[a/x] n[a/x])$: we recursively perform capture-avoiding substitution on the two expressions in the application.
- $(λx.b)[a/x] = λx.b$: the variable $x$ is already bound by the abstraction, so there are no occurrences of the free variable $x$ that can be substituted.
- $(λy.b)[a/x] = λy.(b[a/x])$ if $x\ne y$ and $y$ is not a free variable in $a$.

That last rule subtly avoids the problem we observed earlier. It prevents us from substituting an expression containing free variables that would be unintentionally captured. If $y$ does occur as a free variable in $a$, then we must alpha-reduce the abstraction so that its parameter does not occur as a free variable in $a$ before performing beta-reduction.

Eta-reduction converts $λx.gx$ to $g$ where $g$ is any expression. This makes sense as there is no real difference between an abstraction that applies $g$ to an argument, and $g$ itself. However, we must ensure that $x$ does not occur as a free variable in $g$. Consider $λx.xx$; we cannot eta-reduce this because it is clearly different from $x$.

# Boolean algebra

The amazing thing about this symbol-shunting calculus is that it is incredibly powerful! It's hard to believe at first, but the λ-calculus can compute anything that is computable in theory. This includes everything your computer can do, and much more. We'll start with Boolean algebra.

Their are two values in Boolean algebra: True and False. We'll represent True with $T\coloneqq λx.λy.x$ and False with $F\coloneqq λx.λy.y$. For clarity, we'll use the letters $T$ and $F$ in expressions, although to make a correct λ-expression you need to replace them with their values. Note that, if we perform the application $bxy$ where $b$ is a Boolean, then the result will be $x$ if $b$ is True, and $y$ if $b$ is False. A secondary interpretation of $T$ and $F$, then, is that they select the first or second of two items.

There are three principle Boolean operations: conjunction (And), disjunction (Or), and negation (Not). Here are their implementations:

| Operation | Expression  |
| --------- | ----------- |
| And       | $λa.λb.abF$ |
| Or        | $λa.λb.aTb$ |
| Not       | $λa.aFT$    |

The operation And takes two Boolean parameters. It then applies $a$ to two arguments, which selects one based on the value of $a$. If $a$ is True, it returns $b$, and if $a$ is False, it returns False. Try doing the beta-reduction on paper for each of the four input combinations -- you'll see that it gives the correct answer every time! If you understand how And works, it shouldn't be too hard to figure out Or and Not.

# Church numerals

The Booleans we implemented are actually called Church Booleans because they use Church encoding, named after Alonzo Church. We can also encode the natural numbers in this way, producing Church numerals.

We represent zero with $Z\coloneqq λh.λx.x$. One is $λh.λx.hx$, two is $λh.λx.h(hx)$, five is $λh.λx.h(h(h(h(hx))))$, and so on. To represent some number, we simply apply $h$ that many times. With Church numerals, we can recover all of arithmetic! I'll implement the successor operator (adds one) as well as addition, multiplication, and exponentiation:

| Operation | Expression            |
| --------- | --------------------- |
| Succ      | $λn.λh.λx.h(nhx)$     |
| Add       | $λn.λm.λh.λx.nf(mfx)$ |
| Mult      | $λn.λm.λh.n(mh)$      |
| Pow       | $λn.λm.mn$            |

If you taught someone the rules of the λ-calculus, you could have them compute sums, products, and powers, and they would have no idea they were doing it! It looks like mindless symbol-manipulation, but it corresponds directly to our usual arithmetic.

# Conclusion

I've only scratched the surface of the λ-calculus in the article. There are many more data types we could Church-encode, including linked lists. It's also possible to define higher order functions like maps and filters -- before you know it, you'll have a full-featured functional programming language. In fact, Lisp was deliberately designed on a λ-calculus core over 50 years ago! I encourage you to check out my project [Lam][lam] if you get tired of doing the reductions by hand. I'd love to twist your brain into a pretzel by showing how you can make recursive abstractions using the Y combinator, but that will have to wait for its own article.

[lam]: https://github.com/mk12/lam
