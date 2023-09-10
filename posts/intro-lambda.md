---
title: Introduction to the λ-calculus
subtitle: Meet your new favourite formal system
category: Math
date: 2015-04-07T12:48:12-04:00
---

Most people think of Newton and Leibniz's infinitesimal calculus when they hear the word _calculus_, but the term is actually more general than that. A calculus is a formal system of calculation or reasoning, usually involving the symbolic manipulation of expressions. The λ-calculus (_lambda calculus_) is one such system, and it is very important in computer science.

# Expressions

Everything in the λ-calculus is an expression. There are three types of expressions: variables, abstractions, and applications:

1. A _variable_ is represented by a letter such as _x_. The letter has no purpose other than to distinguish one variable from another.
2. An _abstraction_ has the form _λx.e_ where _x_ must be a variable and _e_ can be any expression. You can think of it as an anonymous function of one parameter _x_ with a function body _e_.
3. An _application_ has the form (_h x_) where _h_ and _x_ are expressions. If _h_ is an abstraction, then this is like applying a function _h_ to an argument _x_.

Using this recursive definition, we can tell whether any string of characters is a valid λ-expression. For example, _λx.λ_ is invalid because the part after the abstraction's period should be an expression, but λ by itself is not an expression. On the other hand, _λa.λb.λc.c_ is a well-formed expression.

To interpret λ-expressions unambiguously, we need a few conventions:

- Outer parentheses are unnecessary: (((_x_))) is the same as _x_.
- Applications are left-associative: ((_a_ _b_) _c_) is the same as _a b c_. On the other hand, the parentheses in _a_&nbsp;(_b c_) are necessary to preserve meaning.
- Abstraction bodies extend as far to the right as possible: _λx._(_x x_) is the same as _λx.x x_, which is different from the application (_λx.x_) _x_.

# Free variables

When we look at all the variables in a given λ-expression, we classify some as _free variables_. A variable by itself, such as _x_, is always a free variable. However, the _x_ in _λx.x_ is not free because the abstraction _binds_ it; we call these variables _bound variables_. All variables are free until they are bound in an enclosing abstraction. Let's look at some examples:

| Expression | Free variables |
|:----------:|:--------------:|
| _x_ | _x_ |
| _λx.x x_ | --- |
| _λx.y_ | _y_ |
| _λy.λx.y_ | --- |
| _a_ (_b c_) _d_ | _a_, _b_, _c_, _d_ |
| (_λa.a b_) _a_ | _a_, _b_ |

Be careful with that last example. Clearly _b_ is a free variable, but what about _a_? It looks like _a_ occurs three times, but there are actually two distinct variables here! The _a_ that occurs in the abstraction is a bound variable, while the rightmost _a_ is a free variable. When a variable is bound, everything inside the abstraction refers to this new bound variable, regardless of what the variable means outside. In these cases, we say that the new bound variable _shadows_ the free variable. To drive the point home, consider the expression _a λa._(_a λa._(_a λa.a_)). Here we have four distinct variables -- one free and three bound -- and they all reuse the letter _a_.

One final thing to note is that a variable's freedom depends on the scope being considered. If we consider _λx.b x_ as a whole, then _x_ is a bound variable. Even so, it is equally correct to say that _x_ is a free variable in _b x_ of that expression. For this reason, we should always be clear if we are talking about the whole expression or just a part of it.

# Reduction

The heart of the lambda calculus lies in the reduction of expressions. Reduction is a process guided by a set of simple yet powerful rules, and it is the essential component that allows us to call the λ-calculus a calculus. There are three methods of reducing expressions, named using the Greek letters alpha, beta, and eta.

Alpha-reduction allows us to rename parameters in abstractions. We do this by changing the parameter, including and all its occurrences in the body, to a new letter. For example, _λx.x_ is alpha-equivalent to _λn.n_. The parameter is just a placeholder -- it's name doesn't really matter. However, there are two restrictions on alpha-reduction. First, the new variable must not occur as a free variable in the body. Consider _λa.a b_, an abstraction that applies its argument to _b_. If we rename _a_ to _b_, we get _λb.b b_, an abstraction that applies its argument to itself -- something went wrong here! This new expression has a different meaning because we inadvertently captured the free variable _b_, making it a bound variable. Second, the old variable must not occur in an abstraction where the new variable is already bound. Consider _λa.λb.a_; if we rename _a_ to _b_, we get _λb.λb.b_, which is different because _b_ now refers to the inner bound variable rather than the outer one. As long as we avoid these two cases, alpha-reduction always results in expressions that intuitively have the same meaning.

**TODO: fix brackets**
```
Beta-reduction is what really makes things happen. It only works on applications of abstractions, and you can think of it as function application. An expression of the form (_λx.e_)&nbsp;_a_ beta-reduces to _e_[_a/x_], which denotes _e_ with _a_ substituted for all occurrences of _x_ in a special way called capture-avoiding substitution. For example, (_λx.x x_) _u_ is beta-equivalent to _u u_. However, it is not so straightforward to reduce (_λx.λy.x_) _y_ because it should be an abstraction that always returns the free variable _y_, but simple substitution yields _λy.y_, which returns the bound variable _y_ instead! We avoid this problem using capture-avoiding substitution:

- _x_[_a/x_] = _a_, just like simple substitution.
- _y_[_a/x_] = _y_ if _x_ ≠ _y_, also like simple substitution.
- (_h n_)[_a/x_] = (_h_[_a/x_] _n_[_a/x_]): we recursively perform capture-avoiding substitution on the two expressions in the application.
- (_λx.b_)[_a/x_] = _λx.b_: the variable _x_ is already bound by the abstraction, so there are no occurrences of the free variable _x_ that can be substituted.
- (_λy.b_)[_a/x_] = _λy._(_b_[_a/x_]) if _x_&nbsp;≠&nbsp;_y_ and _y_ is not a free variable in _a_.
```

That last rule subtly avoids the problem we observed earlier. It prevents us from substituting an expression containing free variables that would be unintentionally captured. If _y_ does occur as a free variable in _a_, then we must alpha-reduce the abstraction so that its parameter does not occur as a free variable in _a_ before performing beta-reduction.

Eta-reduction converts _λx.g x_ to _g_ where _g_ is any expression. This makes sense as there is no real difference between an abstraction that applies _g_ to an argument, and _g_ itself. However, we must ensure that _x_ does not occur as a free variable in _g_. Consider _λx.x x_; we cannot eta-reduce this because it is clearly different from _x_.

# Boolean algebra

The amazing thing about this symbol-shunting calculus is that it is incredibly powerful! It's hard to believe at first, but the λ-calculus can compute anything that is computable in theory. This includes everything your computer can do, and much more. We'll start with Boolean algebra.

Their are two values in Boolean algebra: True and False. We'll represent True with _T_&nbsp;:=&nbsp;_λx.λy.x_ and False with _F_&nbsp;:=&nbsp;_λx.λy.y_. For clarity, we'll use the letters _T_ and _F_ in expressions, although to make a correct λ-expression you need to replace them with their values. Note that, if we perform the application _b x y_ where _b_ is a Boolean, then the result will be _x_ if _b_ is True, and _y_ if _b_ is False. A secondary interpretation of _T_ and _F_, then, is that they select the first or second of two items.

There are three principle Boolean operations: conjunction (And), disjunction (Or), and negation (Not). Here are their implementations:

| Operation | Expression |
|:---------:|:-----------|
| And | _λa.λb.a b F_ |
| Or  | _λa.λb.a T b_ |
| Not | _λa.a F T_ |

The operation And takes two Boolean parameters. It then applies _a_ to two arguments, which selects one based on the value of _a_. If _a_ is True, it returns _b_, and if _a_ is False, it returns False. Try doing the beta-reduction on paper for each of the four input combinations -- you'll see that it gives the correct answer every time! If you understand how And works, it shouldn't be too hard to figure out Or and Not.

# Church numerals

The Booleans we implemented are actually called Church Booleans because they use Church encoding, named after Alonzo Church. We can also encode the natural numbers in this way, producing Church numerals.

We represent zero with _Z_&nbsp;:=&nbsp;_λh.λx.x_. One is _λh.λx.h x_, two is _λh.λx.h_&nbsp;(_h x_), five is _λh.λx.h_&nbsp;(_h_&nbsp;(_h_&nbsp;(_h_&nbsp;(_h x_)))), and so on. To represent some number, we simply apply _h_ that many times. With Church numerals, we can recover all of arithmetic! I'll implement the successor operator (adds one) as well as addition, multiplication, and exponentiation:

| Operation | Expression |
|:---------:|:-----------|
| Succ | _λn.λh.λx.h (n h x)_ |
| Add  | _λn.λm.λh.λx.n f (m f x)_ |
| Mult | _λn.λm.λh.n (m h)_ |
| Pow  | _λn.λm.m n_ |

If you taught someone the rules of the λ-calculus, you could have them compute sums, products, and powers, and they would have no idea they were doing it! It looks like mindless symbol-manipulation, but it corresponds directly to our usual arithmetic.

# Conclusion

I've only scratched the surface of the λ-calculus in the article. There are many more data types we could Church-encode, including linked lists. It's also possible to define higher order functions like maps and filters -- before you know it, you'll have a full-featured functional programming language. In fact, Lisp was deliberately designed on a λ-calculus core over 50 years ago! I encourage you to check out my project [Lam][lam] if you get tired of doing the reductions by hand. I'd love to twist your brain into a pretzel by showing how you can make recursive abstractions using the Y combinator, but that will have to wait for its own article.

[lam]: https://github.com/mk12/lam
