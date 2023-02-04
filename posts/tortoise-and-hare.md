---
title: "The tortoise and the hare"
description: "Cycle detection with the help of Aesop's fables"
categories: ["algorithms"]
math: true
date: "2015-04-02T15:43:46-04:00"
---

The tortoise and the hare is my favourite algorithm. It's such a neat solution, based on a principle that, while simple, would require a profound insight to discover on your own. You could just memorize the steps in case it comes up in an interview, but I'd like to focus on proving its correctness, which requires a deeper understanding.

<!--more-->

# Introduction

Also known as Floyd's cycle-finding algorithm, its purpose is to detect cycles in linked structures. If you don't know what a linked list is, you may want to look that up first. Picture a set of boxes (nodes), each having an arrow (pointer) to another box. The last box in the list points to nothing, which we refer to as _null_. To traverse the list, we simply follow the arrows. There's nothing to prevent arrows from pointing back to previous boxes, which is a problem because this makes the list infinite. If we follow a million arrows and the list keeps going, there's no way of knowing if it's infinite or if it just happens to be a million and one items long.

{{< img src="linked-lists.svg" cap="Box-and-arrow diagrams of a regular linked list (top) and one with a cycle (bottom)" >}}

In addition to detecting the cycle, the algorithm determines the beginning of the cycle and its period. In the diagram above, the cycle begins at "L" and has a period of 3, because three jumps takes you back to the same spot. The tortoise and hare algorithm is not the only way of doing this, but it's unique in that it uses just two pointers and no additional memory. We could go through the list and build up a set data structure (implemented as a tree or hash table), stopping when the next item is already in the set, but that requires lot of memory if the list is large.

Let's assume the hare runs twice as fast as the tortoise. Clearly the hare will reach the finish line before the tortoise. But what if it was a never-ending circular race track? The hare would always be ahead, but eventually he would be so far ahead that he laps the tortoise! The key difference when the track has a cycle, then, is that at some point other than the beginning, _the hare will be at the same spot as the tortoise_. Once the cycle has been detected, we send the hare back to the beginning and advance both of them at the same speed until they meet again---and we can prove that this second meeting place will be the start of the cycle. Finally, the tortoise rests while the hare does a victory lap to find the period of the cycle.

# Proof of correctness

I'm going to describe the algorithm mathematically first, then write it in code. Let \\(S\\) represent the set of all nodes; in practice, this will be a subset of the addresses in RAM, since we identify nodes with memory addresses.[^1] Let &thinsp;\\(f\colon S \to S \cup \\{0\\}\\) where \\(0\\) is the null node, such that &thinsp;\\(f(n)\\) yields the node pointed to by \\(n\\). Let \\(x\_0\\) be the first node in the linked list, and let \\(x\_i = f^{\circ i}(x\_0)\\) for any _index_ \\(i > 0\\), where \\(\circ n\\) denotes \\(n\\) repeated applications. Let \\(\mu\\) be the index of the start of the cycle, and let \\(\lambda\\) be the period of the cycle. Then \\(x\_{i+k\lambda} = x\_i\\) (**1**) for all integers \\(i \ge \mu\\) and \\(k \ge 0\\); in other words, going around the loop any number of times takes you back to the same node, as long as you start somewhere on the loop. Let \\(t\\) represent the index of the tortoise. Since the hare runs twice as fast of the tortoise, its index is \\(2t\\). When they first meet, we have \\(x\_t = x\_{2t}\\). If we let \\(k\\) be the number of laps by which the hare is ahead, then \\(2t = t + k\lambda\\). Subtracting \\(t\\), we find \\(t = k\lambda\\), thus \\(\lambda\\) divides \\(t\\).

Now, if we return the the hare to the beginning and advance both one node at a time, they will meet again at some index \\(i \ge \mu\\). However, since \\(t\\) is a multiple of \\(\lambda\\), by Equation (**1**) we have \\(x\_{i+t} = x\_i\\). In particular, we can choose \\(i = \mu\\), so \\(x\_{t+\mu} = x\_{\mu}\\). Therefore when the hare advances \\(\mu\\) positions from \\(x\_0\\) to \\(x\_{\mu}\\), the tortoise will also be at \\(x\_{\mu}\\)! After that, if we advance the hare one node at a time until it returns to \\(x\_{\mu}\\), clearly it will only go around once, thus the number of jumps is equal to \\(\lambda\\).

# Scheme implementation

Linked lists are the bread and butter of Lisp, so I'm going to implement the algorithm in Scheme, a simple dialect of Lisp. To construct a node in Scheme, we use `(cons a b)`, where `a` and `b` go in the left and right parts of the box, respectively. For example, to make a list with only one node, containing "A" and pointing to null, we would write `(cons "A" '())`, since null is pronounced `'()` in Scheme. To extract the parts, we use the functions `car` and `cdr`.[^2] We don't care how these three functions work---all we care about is that they satisfy the following two properties:

- `(car (cons a b))` evaluates to `a`;
- `(cdr (cons a b))` evaluates to `b`.

First, we'll define `detect-cycle`, which will put the tortoise and hare in their starting positions. Given the first node, this function will return \\((\mu,\lambda)\\) if there is a cycle and `#f` otherwise (the false value in Scheme). It will rely on three nested functions that we'll implement after. I'm putting them inside `detect-cycle` because they aren't useful on their own, and because one of them need to access the `x0` parameter.

{{< highlight scheme >}}
(define (detect-cycle x0)
  (define (race t h) ...)
  (define (find-mu t h) ...)
  (define (find-lambda t h) ...)
  (if (or (null? x0) (null? (cdr x0)) (null?  (cddr x0)))
    #f
    (race (cdr x0) (cddr x0))))
{{< /highlight >}}

The beginning is a special case---the tortoise and hare are on the same node, but it doesn't count because we're looking for the _next_ time they meet. For that reason, we place them at \\(x\_1\\) and \\(x\_2\\) and pass them to the `race` function. Before doing that, though, we have to make sure we actually _have_ three nodes! It's illegal to call `car` or `cdr` on `'()`, so these checks are necessary. Note that `(cddr x)` is short for `(cdr (cdr x))`.

Now, let's implement `race` recursively. It should advance the tortoise by one position and the hare by two until they meet:

{{< highlight scheme >}}
(define (detect-cycle x0)
  (define (race t h)
    (cond ((or (null? t) (null? h) (null? (cdr h))) #f)
          ((eq? t h)
           (list (find-mu t x0)
                 (find-lambda t (cdr h))))
          (else (race (cdr t) (cddr h)))))
  ...)
{{< /highlight >}}

There are three possibilities. If the tortoise or hare is null, then there is obviously no cycle since we've reached the end. We also need to make sure that `(cdr h)` isn't null, since we might be calling `(cddr h)` after. Next, we check if the tortoise and hare are the same using `eq?`. If so, we've found the first meeting place, so we go on to find \\(\mu\\) and \\(\lambda\\), and we return a list containing both of them. For `find-mu`, we leave the tortoise as is, but we pass `x0` as second argument to move the hare back to the beginning. For `find-lambda`, we move the hare forward right away to avoid that same special case I mentioned before. Finally, if they haven't met yet and there is no null in sight, then we continue the race, advancing the tortoise by one jump and the hare by two.

Once the race is over, `find-mu` gets to do its job. It returns how many jumps it takes for the tortoise and hare to be reunited:

{{< highlight scheme >}}
(define (detect-cycle x0)
  ...
  (define (find-mu t h)
    (if (eq? t h)
      0
      (+ 1 (find-mu (cdr t) (cdr h)))))
  ...)
{{< /highlight >}}

This function is easily expressed recursively.[^3] If the tortoise and hare are already at the same spot, then the cycle must start at the beginning of the list, so we return 0. Otherwise, it's one greater than the number of jumps it takes to bring them together _after_ advancing both by one position.

Finally, `find-lambda` returns the number of jumps it takes for the hare to go around the loop and return to the tortoise:

{{< highlight scheme >}}
(define (detect-cycle x0)
  ...
  (define (find-lambda t h)
    (if (eq? t h)
      1
      (+ 1 (find-lambda t (cdr h)))))
  ...)
{{< /highlight >}}

Recall that in `race` we started off the hare one jump ahead of the tortoise. If they're the same right away, then the period must be 1 because it takes one jump to return to the same spot. Otherwise, it's one greater than the number of jumps it takes to return to the tortoise _after_ advancing the hare by one position.

# Conclusion

If you want to try out the Scheme implementation, I recommend [Racket][rkt] or [Gambit Scheme][gs]. Or, if you don't feel like leaving your browser, check out the great web app [repl.it][repl]. If you're interested in learning more about programming with Lisp, I highly recommend the computer science classic [_Structure and Interpretation of Computer Programs_][sicp]. You will easily pick up Scheme by reading it, but that's not its purpose at all---Scheme's syntax is so simple that it needs little explanation, and this allows the book to focus on important concepts instead of the minutiae of a particular language. The full text is available on the MIT website, but if you're serious about reading it, do your eyes a favour and download the [pretty PDF version][spdf].

[^1]: To be clear, the nodes of the list are the boxes themselves. Each box will have some data associated with it, like the letters I put in the diagram, but we don't care about that for this algorithm.

[^2]: They are named this way for historical reasons: `car` meant "contents of the address part of the register", and `cdr` meant "contents of the decrement part of the register."

[^3]: You could easily rewrite `find-mu` and `find-lambda` in an iterative style (allowing for tail-call optimization) by passing a count parameter. Both methods use recursion, but the iterative approach is more efficient.

[rkt]: http://racket-lang.org
[gs]: http://gambitscheme.org
[repl]: http://repl.it/languages/Scheme
[sicp]: https://mitpress.mit.edu/sicp/
[spdf]: https://sicpebook.wordpress.com/ebook/
