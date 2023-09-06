---
title: Assertions and beyond
subtitle: Modern methods of testing software
category: Software
date: 2015-08-02T23:47:34-04:00
---

Writing code that works is hard. It doesn't matter how many times you've gone over it, or how many coworkers have reviewed it. A developer with any experience never expects it to work the first time. If you've just written a thousand lines and they seem to work as expected, your initial reaction should be suspicion -- it will lead to less embarrassment in the long run.

# Testing 1-2-3

Test suites are meant to fix this problem, or at least improve the situation. The idea is this: write code that does what you want, then write more code to make sure it works. The second step produces a collection of tests. The better your tests, the more confident you can be in your code. Advocates of test-driven development (TDD) would tell you to write the tests _first_, and the implementation second. I think TDD is great, but I don't use it for everything -- I sometimes prefer an exploratory style of programming, and writing extensive tests before my ideas are solidified seems like a waste of time more often than not.[^1]

Tests are especially useful when it's time to _refactor_ code. Refactoring code just means changing it without changing what it does. This is usually done to improve the code by making it more readable, maintainable, modular, or otherwise better. Without tests, large refactorings can be very dangerous. With tests, you can be fairly confident that you haven't broken everything.

Tests come in many flavours. Some carry out basic sanity checks; others perform complicated setup routines and probe every detail of the result. Most tests fall under one of two broad categories: unit and integration. Unit tests consider individual units of code in isolation, while integration tests bring the parts together and test them as systems. Tests are said to _exercise paths_ in the implementation code -- the more paths exercised, the better. Developers sometimes measure the fraction of code covered by tests as a percentage and call it _code coverage_. High code coverage is especially important for software written in dynamically typed languages, as none of the work can be offloaded onto the type system. Static type systems don't eliminate the need for tests, but they give you many correctness guarantees for free.

One interesting way of testing your tests (yes, that's a thing) is a technique called _fault injection_. You inject faults by changing the implementation to make it incorrect, and then you run your test suite, expecting failures. If all tests pass, then something is wrong and you need to write more tests. If it fails, then you can pat yourself on the back for having decent coverage.

# Assert the truth

The fundamental building block of tests is the _assertion_. If you expect something to be true, you should assert it in a test. If it turns out to be false, the test will fail, and it's your job to figure out why it failed. The simplest unit of code to test is a pure function.[^2] Consider a Ruby function that returns the square of a number:

```ruby
def square(n)
  n * n
end

...

test "square returns the square of its input" do
  assert square(-1) == 1
  assert square(0) == 0
  assert square(5) == 25
end
```

This is a very simple example. It doesn't guarantee that the function works, but it does make sure nothing is horribly wrong. Basic assertions like these can take you a long way. Some assertions are so common that they deserve special shortcuts. Here's a typical controller test that you might see in a Rails app:

```ruby
test "#create creates a new user with name and email" do
  assert_difference 'User.count', +1 do
    post :create, user: {name: "First Last", email: "test@example.com"}
  end

  new_user = User.order(id: :desc).first
  assert_redirected_to new_user
  assert_equal "First Last", new_user.name
  assert_equal "test@example.com", new_user.email
end
```

This is a bit fancier, but it's still just asserting that specific things are true. It's great when tests can remain simple like this, but it doesn't work for everything. When code becomes difficult to test, we need to apply some more advanced methods.

# Fixtures and factories

One of the biggest problems in testing is _data_. If you're unit testing a single function, it's easy: just test it with a few different inputs, carefully chosen to exercise all possible execution paths. But if your code has to interact with a database, you're going to have to provide fake data.

One approach is to maintain a special collection of test data, striving for a reasonable variety without going overboard. In Rails, these are called _fixtures_, and they are stored in YAML files. This doesn't sound bad, but it can become painful when there are complex relationships between objects. Another problem with fixtures is that they can become brittle due to badly written test cases depending on a very particular configuration. In those situations, it's far from obvious what you can add or change without breaking existing tests. If written carefully and used properly, though, fixtures can be an excellent solution.

Factories are an alternative method of generating test data. [FactoryGirl][fg] is a popular Ruby library that uses this method. I can't say too much about it because I've never used it, but many people cite advantages over fixtures: less brittle, more flexible, easier to keep up to date, and generally more pleasant to work with. I certainly think it's an option worth exploring.

# Mocks, stubs, and expectations

Sometimes faking data isn't enough -- tests need to fake behaviour as well. This is where the fancy stuff provided by test frameworks comes in. The terminology is sometimes a source of confusion, but most people will know what you're talking about if you mention _mocks_ or _stubs_. Suppose you have a class that sends emails. You don't want to actually send emails while running tests, so you swap it out for a fake:

```ruby
class FakeMailer
  def initialize(from, subject, body)
    @from = from
    @subject = subject
    @body = body
  end

  def num_words
    @body.split.count
  end

  def send(to_address)
    true
  end
end
```

The real `send` method should be doing a lot more, but this is just a fake. This sort of thing is fine, but writing dummy classes for everything is tedious. Frameworks like [Mocha][mocha] make it much easier:

```ruby
fake = mock()
fake.name # => NoMethodError

fake.stubs(name: "Mitchell")
fake.name # => "Mitchell"

fake.stubs(:square).with(2).returns(4)
fake.stubs(:square).with(3).returns(9)
fake.square(2) # => 4
fake.square(3) # => 9
```

Mocha allows us to create mock objects and stub out their methods by providing canned return values. You won't see `mock()` very often because there are some convenient alternatives:

```ruby
fake = stub(name: "Mitchell", age: 19)
fake.name # => "Mitchell"
fake.age  # => 19

stub(a: stub(b: stub(c: "abc"))).a.b.c # => "abc"

number = 15
number.to_s # => "15"
number.stubs(to_s: "Fifteen")
number.to_s # => "Fifteen"

String.any_instance.stubs(downcase: "bunny")
"BUNNY".downcase  # => "bunny"
"RABBIT".downcase # => "bunny"
```

Related to stubs are _expectations_. An expectation is like a stub, but it goes one step further: it verifies that it gets called a certain number of times. If it doesn't, then the test fails. Going back to the email example, we might use an expectation like this:

```ruby
test "#contact delivers an email to test@example.com" do
  Mailer.any_instance.expects(:send).with('test@example.com').returns(true).once
  post :contact, message: "Hello"
end
```

If the `send` method doesn't get called at some point before the end of the test case, the test will fail. If it does get called, and the correct argument is provided, it will return true. It's also possible to "expect" a method to be called twice, or some specific number of times. I almost always use `once` (or you can leave it out -- it's the default), but I also find `never` useful: it verifies that the method never gets called.

# Conclusion

Software testing is an active area of research and exploration. Nowadays it's unheard of to develop large systems without tests, but not all tests are created equal. It takes time and effort to produce high-quality tests, so it's worthwhile to take advantage of techniques like stubs and expectations. There are plenty of flashy new frameworks to try out, but beyond that, writing good tests is something of an art -- one that I'm working on improving, both at work and in my personal projects.

[^1]: David Heinemeier Hansson has [some interesting thoughts][tdd] on this subject.

[^2]: A _pure function_ is a function that is idempotent and has no side effects. Idempotence means always returning the same output for a given set of inputs. Side effects include things such as  mutating global state and external I/O.

[tdd]: http://david.heinemeierhansson.com/2014/tdd-is-dead-long-live-testing.html
[fg]: https://github.com/thoughtbot/factory_girl
[mocha]: https://github.com/freerange/mocha
