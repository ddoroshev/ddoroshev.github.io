---
layout: post
title:  "Welcome to Jekyll!"
date:   2023-12-10 12:59:36 +0000
categories: jekyll update
---

> <sup>TL;DR</sup> https://github.com/ddoroshev/c-inheritance

Sometimes you want to abstract and generalize something in C code. For example, if you want to print the contents of a structure multiple times, you end up writing `printf("%s %d %f\n", foo->bar, foo->baz, foo->boom)` everywhere like a fool, and it intuitively seems that there should be a way to do `foo->print(foo)`, and not just with `foo`, but with any structure.

Let's take an example: there is a guy with a first name and a last name, and there is a bird that has a name and an owner.

```c
typedef struct Person Person;
struct Person {
    char *first_name;
    char *last_name;
};

typedef struct Bird Bird;
struct Bird {
    char *name;
    Person *owner;
};
```

To print information about these animals, a cunning C programmer would simply write two functions:

```c
void Person_Print(Person *p) {
    printf("%s %s\n", p->first_name, p->last_name);
}

void Bird_Print(Bird *b) {
    printf("%s of %s %s\n", b->name, b->owner->first_name, b->owner->last_name);
}
```

And they would be right! But what if we have many such structures and our brains are corrupted by OOP? <!--cut--> Right, we need to define a common method for each structure, for example `void Repr(Person* person, char* buf)`, which will write the string representation of the object to `buf`, and then we could use this result for output:

```c
/* Person */
struct Person {
    void (*Repr)(Person*, char*);
    /* ... */
};

void Person_Repr(Person *person, char *buf) {
    sprintf(buf, "<Person: first_name='%s' last_name='%s'>",
            person->first_name, person->last_name);
}

Person *New_Person(char *first_name, char *last_name) {
    Person *person = malloc(sizeof(Person));
    person->Repr = Person_Repr;
    person->first_name = first_name;
    person->last_name = last_name;
    return person;
}

/* Bird */
struct Bird {
    void (*Repr)(Bird*, char*);
    /* ... */
};

void Bird_Repr(Bird *bird, char* buf) {
    char owner_repr[80];
    bird->owner->Repr(bird->owner, owner_repr);
    sprintf(buf, "<Bird: name='%s' owner=%s>",
            bird->name, owner_repr);
}

Bird *New_Bird(char *name, Person *owner) {
    Bird *bird = malloc(sizeof(Bird));
    bird->Repr = Bird_Repr;
    bird->name = name;
    bird->owner = owner;
    return bird;
}
```

Okay, we've unified it, but not really. How do we call these methods now? It's not very convenient, we have to deal with buffers every time:

```c
char buf[80];
bird->Repr(bird, buf);
printf("%s\n", buf);
```

As an option, we can create a base structure `Object`, put the `Print()` function in it, "inherit" other structures from `Object`, and in `Object::Print()` call the child method `Repr()`. It looks logical, but we are writing in C, not in C++, where this can be easily solved with virtual functions.

But in C there is a thing: you can cast one structure to another if it has that other structure as its first field.

For example:

```c
typedef struct {
    int i;
} Foo;

typedef struct {
    Foo foo;
    int j;
} Bar;

Bar *bar = malloc(sizeof(Bar));
bar->foo.i = 123;
printf("%d\n", ((Foo*)bar)->i);
```

That is, we look at the `bar` structure, but with the type `Foo`, because essentially a pointer to a structure is a pointer to its first element, and we have the right to cast it like this.

Let's try to create a base structure `Object` with one function `Print_Repr()`, which should call the "child method" `Repr()` of our people and birds:

```c
typedef struct Object Object;
struct Object {
    void (*Print_Repr)(Object*);
};

/*
 The most interesting part. The function takes a pointer
 to the next field in the structure after Object,
 which in the current version is a pointer
 to the Repr() function.
 */
void Object_Print_Repr(Object *object) {
    void **p_repr_func = (void*) object + sizeof(Object);
    void (*repr_func)(Object*, char*) = *p_repr_func;
    char buf[80];
    repr_func(object, buf);
    printf("%s\n", buf);
}

/* Person */
typedef struct Person Person;
struct Person {
    Object object;
    void (*Repr)(Person*, char*);
    /* ... */
};

Person *New_Person(char *first_name, char *last_name) {
    Person *person = malloc(sizeof(Person));
    person->object.Print_Repr = Object_Print_Repr;
    person->Repr = Person_Repr;
    /* ... */
    return person;
}

/* Bird */
typedef struct Bird Bird;
struct Bird {
    Object object;
    void (*Repr)(Bird*, char*);
    /* ... */
};

Bird *New_Bird(char *name, Person *owner) {
    Bird *bird = malloc(sizeof(Bird));
    bird->object.Print_Repr = Object_Print_Repr;
    bird->Repr = Bird_Repr;
    /* ... */
    return bird;
}
```

So we have implemented the "Template Method" pattern in pure C. Not quite fair, and not quite reliable, but it somehow works.

There are two questions here:
1. What if the `Repr()` function is not the second field in the structure?
2. What if we want to support more than one function?

The answer is not pleasant, because it spoils the beauty and purity of the base `Object` structure, we need to add the addresses of the functions we need there. It's not difficult to get them, there is a useful macro `offsetof(<struct>, <field>)` in `stddef.h`. It works like this:

```c
struct A {
    char c;
    int i;
    long l;
}

offsetof(struct A, c) == 0;
offsetof(struct A, i) == 4;
offsetof(struct A, l) == 8;
```

With the help of this macro, we can get the offsets of all the necessary generic functions, save them in `Object`, and call them from other methods. Beautiful, isn't it?

Suppose we want to add the `Str()` function to the `Repr()` function, which will represent the object as a string, but without any debugging shell, like `<Person first_name='John' last_name='Smith'>`, but simply form the string `John Smith` for output in some interface. (Do you feel the influence of Python with its `__repr__()` and `__str__()`?)

Accordingly, `Object` should have the corresponding `Print_Str()` function for outputting the results. And to make it hook the right function, we need to dig into all the offsets inside it.

The listing will be longer than the others, with comments, but don't be afraid, we will refactor it soon.

```c
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

typedef struct Object Object;
typedef struct Person Person;
typedef struct Bird Bird;

struct Object {
    size_t offset_repr;
    void (*Print_Repr)(Object*);

    size_t offset_str;
    void (*Print_Str)(Object*);
};

/*
 Get the function by the address object + offset_repr,
 cast it to void(*)(Object*, char*) and call it,
 passing the address of the current object.
 */
void Object_Print_Repr(Object *object) {
    void **p_repr_func = (void*) object + object->offset_repr;
    void (*repr_func)(Object*, char*) = *p_repr_func;
    char buf[80];
    repr_func(object, buf);
    printf("%s\n", buf);
}

/*
 The same thing, but now instead of offset_repr we take offset_str.
 The function signature is the same, so there's nothing else interesting.
 */
void Object_Print_Str(Object *object) {
    void **p_str_func = (void*) object + object->offset_str;
    void (*str_func)(Object*, char*) = *p_str_func;
    char buf[80];
    str_func(object, buf);
    printf("%s\n", buf);
}

/*
 Pay attention to the order of fields in the structure,
 now they can be grouped as desired.
 */
struct Person {
    /* "Inherit" from Object */
    Object object;

    /* The actual data */
    char *first_name;
    char *last_name;

    /* "Methods" */
    void (*Repr)(Person*, char*);
    void (*Str)(Person*, char*);
};

/* Person->Repr(...) */
void Person_Repr(Person *person, char *buf) {
    sprintf(buf, "<Person: first_name='%s' last_name='%s'>",
            person->first_name, person->last_name);
}

/* Person->Str(...) */
void Person_Str(Person *person, char *buf) {
    sprintf(buf, "%s %s", person->first_name, person->last_name);
}

/*
 Initialization of Person and the nested Object structure
 */
Person *New_Person(char *first_name, char *last_name) {
    /*
     Collect the data and functions of Person itself.
     */
    Person *person = malloc(sizeof(Person));
    person->first_name = first_name;
    person->last_name = last_name;
    person->Repr = Person_Repr;
    person->Str = Person_Str;

    /*
     Notify the nested Object about the addresses of the "child"
     functions that we are going to call from Object itself.
     */
    person->object.offset_repr = offsetof(Person, Repr);
    person->object.offset_str = offsetof(Person, Str);

    /* And fill it with meaning */
    person->object.Print_Repr = Object_Print_Repr;
    person->object.Print_Str = Object_Print_Str;

    return person;
}

/* Don't forget to clean up after yourself */
void Del_Person(Person *person) {
    free(person);
}

/* Bird is the same as Person */
struct Bird {
    Object object;

    char *name;
    Person *owner;

    void (*Repr)(Bird*, char*);
    void (*Str)(Bird*, char*);
};

void Bird_Repr(Bird *bird, char* buf) {
    char owner_repr[80];
    bird->owner->Repr(bird->owner, owner_repr);
    sprintf(buf, "<Bird: name='%s' owner=%s>",
            bird->name, owner_repr);
}

void Bird_Str(Bird *bird, char* buf) {
    sprintf(buf, "%s", bird->name);
}

Bird *New_Bird(char *name, Person *owner) {
    Bird *bird = malloc(sizeof(Bird));
    bird->name = name;
    bird->owner = owner;
    bird->Repr = Bird_Repr;
    bird->Str = Bird_Str;

    bird->object.offset_repr = offsetof(Bird, Repr);
    bird->object.offset_str = offsetof(Bird, Str);

    bird->object.Print_Repr = Object_Print_Repr;
    bird->object.Print_Str = Object_Print_Str;

    return bird;
}

void Del_Bird(Bird *bird) {
    free(bird);
}

int main(void) {
    Person *person = New_Person("John", "Smith");
    Bird *bird = New_Bird("Cuckoo", person);

    /*
     "Look" at the person object as an Object
     and call the functions with the same object.
     In principle, nothing prevents passing person
     to the function without additional type casting:

       ((Object*)person)->Print_Repr(person);

     GCC will accept it, but will issue a warning.
     */
    ((Object*)person)->Print_Repr((Object*)person);
    ((Object*)person)->Print_Str((Object*)person);

    ((Object*)bird)->Print_Repr((Object*)bird);
    ((Object*)bird)->Print_Str((Object*)bird);

    Del_Bird(bird);
    Del_Person(person);
}
```

Looks cool, but a bit crazy. First, there is a lot of boilerplate code in the initializers, and second, the constant casting `(Object*)` just screams about leaking abstractions.

In principle, the latter problem is not difficult to solve. It is enough to add all the `Print_*` functions to the child structures and provide them with pointers to the same functions from `Object`:

```c
struct Person {
    /* ... */
    /* References to the corresponding Object functions */
    void (*Print_Repr)(Person*);
    void (*Print_Str)(Person*);
};

Person *New_Person(char *first_name, char *last_name) {
    /* ... */
    person->object.Print_Repr = Object_Print_Repr;
    person->object.Print_Str = Object_Print_Str;

    /*
     Insert the same functions into person,
     casting them to void (*)(Person *), so that the compiler
     doesn't complain.
     */
    person->Print_Repr = (void (*)(Person *))Object_Print_Repr;
    person->Print_Str = (void (*)(Person *))Object_Print_Str;

    return person;
}

/* Bird - the same as Person */

int main(void) {
    /* ... */
    person->Print_Repr(person);
    person->Print_Str(person);

    bird->Print_Repr(bird);
    bird->Print_Str(bird);

    /* ... */
}
```

Now it's really beautiful, OOP everywhere! We call the `person->Print_Repr()` method, which is actually `person->object.Print_Repr()`, which in turn calls `person->Repr()` when called.

But there is still too much boilerplate code. Every time we need to describe our OOP machinery in the initializers, and if we miss something - SEGFAULT is waiting!

Introducing - `object.h`:

```c
#pragma once

#include <stddef.h>

/*
 A macro that embeds the necessary object fields.
 */
#define OBJECT(T) \
    Object object; \
    void (*Repr)(T*, char*); \
    void (*Str)(T*, char*); \
    void (*Print_Repr)(T*); \
    void (*Print_Str)(T*);

/*
 An object initializer that adds all
 the necessary functions and offsets.
 */
#define INIT_OBJECT(x, T) \
    x->object.Print_Repr = Object_Print_Repr; \
    x->object._offset_Repr = offsetof(T, Repr); \
    x->object.Print_Str = Object_Print_Str; \
    x->object._offset_Str = offsetof(T, Str); \
    x->Print_Repr = (void (*) (T*)) Object_Print_Repr; \
    x->Print_Str = (void (*) (T*)) Object_Print_Str; \
    x->Repr = T ## _Repr; \
    x->Str = T ## _Str

/* A macro that returns a function pointer by its name */
#define OBJECT_FUNC(x, F) *(void **)((void*) x + x->_offset_ ## F)

typedef struct Object Object;

typedef void *(Repr)(Object *, char*);
typedef void *(Str)(Object *, char*);

/* Our old friends */
struct Object {
    size_t _offset_Repr;
    void (*Print_Repr)(Object*);

    size_t _offset_Str;
    void (*Print_Str)(Object*);
};

void Object_Print_Repr(Object *object) {
    Repr *repr_func = OBJECT_FUNC(object, Repr);
    char buf[80];
    repr_func(object, buf);
    printf("%s\n", buf);
}

void Object_Print_Str(Object *object) {
    Str *str_func = OBJECT_FUNC(object, Str);
    char buf[80];
    str_func(object, buf);
    printf("%s\n", buf);
}
```

And here's how these macros reduce the amount of final code:

```c
typedef struct Person Person;
typedef struct Bird Bird;

struct Person {
    /*
     This is not an ordinary structure, but an inheritor
     of the Object abstraction by name
     */
    OBJECT(Person)
    char *first_name;
    char *last_name;
};

void Person_Repr(Person *person, char *buf) {
    sprintf(buf, "<Person: first_name='%s' last_name='%s'>",
            person->first_name, person->last_name);
}

void Person_Str(Person *person, char *buf) {
    sprintf(buf, "%s %s", person->first_name, person->last_name);
}

Person *New_Person(char *first_name, char *last_name) {
    Person *person = malloc(sizeof(Person));

    /*
     INIT_OBJECT() attaches all the necessary functions,
     including Person_Repr and Person_Str, and puts them
     into the corresponding fields of the structure
     */
    INIT_OBJECT(person, Person);

    person->first_name = first_name;
    person->last_name = last_name;

    return person;
}

/*
 Sorry, but implementing a garbage collector in C
 is a topic for a separate article
 */
void Del_Person(Person *person) {
    free(person);
}

/* Bird is the same as Person */
struct Bird {
    OBJECT(Bird)
    char *name;
    Person *owner;
};

void Bird_Repr(Bird *bird, char* buf) {
    char owner_repr[80];
    bird->owner->Repr(bird->owner, owner_repr);
    sprintf(buf, "<Bird: name='%s' owner=%s>",
            bird->name, owner_repr);
}

void Bird_Str(Bird *bird, char* buf) {
    sprintf(buf, "%s", bird->name);
}

Bird *New_Bird(char *name, Person *owner) {
    Bird *bird = malloc(sizeof(Bird));
    INIT_OBJECT(bird, Bird);

    bird->name = name;
    bird->owner = owner;
    return bird;
}

void Del_Bird(Bird *bird) {
    free(bird);
}

int main(void) {
    Person *person = New_Person("John", "Smith");
    Bird *bird = New_Bird("Cuckoo", person);

    /*
     Call different instances of the "parent" functions
     Print_Repr and Print_Str
     */
    person->Print_Repr(person);
    bird->Print_Repr(bird);

    person->Print_Str(person);
    bird->Print_Str(bird);

    Del_Bird(bird);
    Del_Person(person);
}
```

The most delightful thing about these macros is that they provide compile-time checks. Suppose we decided to add a new structure, "inherit" it from `Object`, but didn't declare the mandatory `Repr` and `Str` methods:

```c
typedef struct Fruit Fruit;

struct Fruit {
    OBJECT(Fruit)
    char *name;
};

Fruit *New_Fruit(char *name) {
    Fruit *fruit = malloc(sizeof(Fruit));
    INIT_OBJECT(fruit, Fruit);

    fruit->name = name;
    return fruit;
}

void Del_Fruit(Fruit *fruit) {
    free(fruit);
}
```

And then the compiler immediately tells us:

```
c_inheritance.c: In function ‘New_Fruit’:
c_inheritance.c:77:24: error: ‘Fruit_Repr’ undeclared (first use in this function)
   77 |     INIT_OBJECT(fruit, Fruit);
      |                        ^~~~~
<...>
c_inheritance.c:77:24: error: ‘Fruit_Str’ undeclared (first use in this function)
   77 |     INIT_OBJECT(fruit, Fruit);
      |                        ^~~~~
```

Very convenient!

So what's the catch here? - you might ask. Since everything is so cool, why not apply it in industrial development?

First of all, your team will think you're insane.

Second, even if they don't, the speed of the program will decrease. And C is used precisely to gain this speed, and often you have to pay for it with code duplication and avoiding abstractions. And despite the fact that modern compilers are super-optimizing, the assembly output from the "OOP" code and the code with a couple of simple functions `Person_Print()` and `Bird_Print()` will differ by one and a half to two times (not in favor of the former), even with `-O3`.

Therefore, this article is purely informational and not a recommendation.

**UPD** Readers rightly pointed out that it is unsafe to use a fixed-size buffer (`char buf[80]`) that I took to simplify the code. In real life, of course, you should allocate a buffer of the final string size:

```c
size_t size = snprintf(NULL, 0, "%s ...", foo, ...);
char *buf = malloc(size + 1);
if (buf == NULL) {
    return 1;
}
sprintf(buf, "%s ...", foo, ...);
/* ... */
free(buf);
```
