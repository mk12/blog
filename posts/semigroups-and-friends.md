---
title: "Semigroups and friends"
description: "A gentle introduction to abstract algebra"
categories: ["math"]
date: "2016-03-10T13:00:00-08:00"
---

What does it take for a semigroup to become a monoid? Why are all groups isomorphic to a group of permutations, and what does that even mean? When do I need to use a field rather than a plain old ring? But more importantly -- what do all these questions have in common?

<!--more-->

You'll be forgiven if you didn't guess _abstract algebra_, because another thing they share is cryptic terminology. Magmas, semigroups, monoids, groups, Abelian groups, rings, and fields -- or as I like to summarize them, semigroups and friends -- are the names mathematicians have given to the things we're about to discuss. Maybe they used up all the good names centuries ago; maybe they want to appear smarter than everyone else; maybe naming things is really hard[^1]. However, the problem with abstract algebra is that it's, well, abstract. These things have no obvious connection to familiar concepts. They are unique entities in eternal Platonic realm.

When I say "things," I mean _algebraic structures_. There are infinitely many algebraic structures, but I'm only going to focus on seven common types. Let me repeat my list: magma, semigroup, monoid, group, Abelian group, ring, and field. Although these intimidating names would have you believe otherwise, the concepts underlying them are quite simple. Understanding them requires no mathematical background other than basic set theory. With that in mind, let's start with some definitions!

An _algebraic structure_ is a set (called the _underlying set_) together with one or more operations on the set that satisfy certain axioms.[^2] The _arity_ of an operation is the number of operands it takes. Most operations are either unary, like negation, or binary, like addition and multiplication. In general, an operation on a set $S$ with arity $n$ is a function $f\colon S^n\to S$. Since operations are conceptually different from ordinary functions, we represent them with symbols rather than letters. The notation also changes a bit: for unary operations we drop the parentheses, and for binary operations we use infix notation. Instead of $\ast(x)$ and $\bullet(x,y)$, we write $\ast x$ and $x \bullet y$.

As is the case for most interesting mathematical objects, interesting algebraic structures usually have patterns. The _axioms_ of an algebraic structure are descriptions of these patterns. Unlike the underlying set and the operations, the axioms are not part of the algebraic structure -- they are facts _about_ it. For any given algebraic structure and axiom, the structure either satisfies the axiom or it doesn't. We could go on forever, observing more and more obscure facts about the structure and calling them axioms. Typically, though, our purpose is to classify algebraic structures by their adherence to a small set of axioms.

Let's construct our first algebraic structure. Let $S=\{\mathrm{a},\mathrm{b}\}$ and let $\ast$ be a unary operation on it where $\ast\mathrm{a}=\mathrm{b}$ and $\ast\mathrm{b}=\mathrm{a}$. Then $(S,\ast)$ is an algebraic structure! Before you dismiss it, take a moment to examine its properties. We know $\ast a=b$, and $\ast(\ast a)=a$, and so on ... is there anything else to learn about it? Well, because this structure is so simple, we can come up with general answers to just about any question that could be asked of it. Observe that all expressions have the form $\ast(\,\dots(\ast x))$, and their values are entirely determined by $x$ and the parity[^3] of the applications of $\ast$. We could make similar statements about the solutions to all possible equations in one or two variables. What we really need, though, is _proof_ -- can you find and prove the general solution to all equations in $(S,\ast)$?

Now we're ready to get acquainted with the semigroup and its friends. Of the seven, the first five have a single binary operation and the last two have two binary operations. We'll start with the simplest one. A _magma_ is an algebraic structure $(S,\bullet)$ where $\bullet$ is a binary operation that is _closed_ over $S$. Notice I say _a_ magma, not _the_ magma; there are infinitely many magmas, each corresponding to different choices for $S$ and $\bullet$. Now, when I say $\bullet$ is "closed over $S$," I mean it has _closure_, which brings us to our first axiom:

1. **Closure**: If $a$ and $b$ are in $S$, then $a\bullet b$ is in $S$ as well.

This axiom is arguably redundant, since an operation on $S$ has codomain $S$ by definition, therefore it must be closed. However, it's customary to include it anyway, for some reasons that I won't go into now.

Most common algebraic properties have names. The property of _closure_ is so common that a statement like, "The operation $\bullet$ has closure over $S$," is rarely accompanied by further explanation. In those cases where explanation is necessary, mathematicians tend to prefer symbols over words for their conciseness and precision. Rather than saying, "If $a$ and $b$ are in $S$, then $a\bullet b$ is in $S$ as well," we can write, $\forall a,b \in S\colon a\bullet b\in S$. Pronouncing $\forall$ as "for all" and $\in$ as "in," this reads, "For all $a$ and $b$ in $S$, $a\bullet b$ is in $S$."

We still have six types of algebraic structure left to go, but instead of defining them one at a time, I'm going to throw five axioms at you:

1. **Closure**: If $a$ and $b$ are in $S$, then $a\bullet b$ is in $S$ as well.
2. **Associativity**: If $a$, $b$, and $c$ are in $S$, then $a\bullet(b\bullet c)=(a\bullet b)\bullet c$.</li>
3. **Identity**: There is an $e$ in $S$ such that $a\bullet e=e\bullet a=a$ for any $a$ in $S$.
4. **Inverse**: For any $a$ in $S$, there is a corresponding $b$ in $S$ such that $a\bullet b=b\bullet a=e$, where $e$ is the identity element.
5. **Commutativity**: If $a$ and $b$ are in $S$, then $a\bullet b=b\bullet a$.

If you're comfortable with predicate logic, you may prefer this format:

|| Name | Axiom |
|:-:|:----:|:------|
|1| Closure | $\forall a,b\in S\colon a\bullet b\in S$ |
|2| Associativity | $\forall a,b,c\in S\colon a\bullet(b\bullet c)=(a\bullet b)\bullet c$ |
|3| Identity | $\exists e\in S\colon\forall a\in S\colon a\bullet e=e\bullet a=a$ |
|4| Inverse | $\forall a\in S\colon\exists b\in S\colon a\bullet b=b\bullet a=e$ |
|5| Commutativity | $\forall a,b\in S\colon a\bullet b=b\bullet a$ |

Magmas, semigroups, monoids, groups, and Abelian groups build on top of each other. In fact, they're nothing more than shorthand for specifying how many of these five axioms to include:

1. **Magma**: An algebraic structure with a closed binary operation (axiom 1).
2. **Semigroup**: An associative magma (axioms 1 and 2)
3. **Monoid**: A semigroup that has an identity element (axioms 1 to 3).
4. **Group**: A monoid that has inverse elements (axioms 1 to 4).
5. **Abelian group**: A commutative group (axioms 1 to 5).

The next two on my list have an extra binary operation, so they need slightly longer definitions. A _ring_ is an algebraic structure with two binary operations $(R,\oplus,\odot)$ where $(R,\oplus)$ forms an Abelian group, $(R,\odot)$ forms a monoid, and $\odot$ is _distributive_ with respect to $\oplus$ on the left and the right:

- **Left distributivity**: $\forall a,b,c\in R\colon a\odot(b\oplus c)=(a\odot b)\oplus(a\odot c)$.
- **Right distributivity**: $\forall a,b,c\in R\colon (b\oplus c)\odot a=(b\odot a)\oplus(c\odot a)$.

A _field_ is a special type of ring. Let $D=R\setminus\{e\}$, where $e$ is the identity element for $\oplus$; that is, $D$ contains the elements of the underlying set except for $e$. Then $(R,\oplus,\odot)$ is a field if $(D,\odot)$ forms an Abelian group.

That's it! You've now been introduced to all seven of them. They may seem peculiar and overly abstract, but you've actually been using these structures ever since you learned arithmetic. In particular, $(\mathbb{Z},+)$ is an Abelian group, $(\mathbb{Z},+,\times)$ is a ring, and $(\mathbb{Q},+,\times)$ is a field. But they aren't the only ones -- the power of abstract algebra is that is allows us to abstract ourselves away from the familiar instances. Rather than studying these specific structures whose underlying sets contain numerals like 1 and 2, mathematicians instead study the general, abstract structure of any such algebra, because the structure is what matters.

Abstract algebra is the study of algebraic structures: sets imbued with structure by operations. Magmas, semigroups, monoids, groups, Abelian groups, rings, and fields are just a few varieties of algebraic structure. And abstract as they are, they do exist in the real world! When you solve a Rubik's cube, you are dealing with group theory. When you split the bill at a restaurant, you are dealing with operations on a field. Each of these is a rich area of mathematics in itself, and I look forward to exploring them further. If you want to learn more about group theory, I recommend [_Introduction to Group Theory_][dog]. You would be surprised at how vast and intricate a world is generated by those four simple axioms.

[^1]: "There are only two hard things in Computer Science: cache invalidation and naming things" (Phil Karlton). I expect the situation with respect to naming things is similar in mathematics.

[^2]: The definition is sometimes extended to allow for zero operations or for more than one underlying set, but we're going to keep things simple.

[^3]: _Parity_ means the fact of being even or odd.

[dog]: http://dogschool.tripod.com/index.html
