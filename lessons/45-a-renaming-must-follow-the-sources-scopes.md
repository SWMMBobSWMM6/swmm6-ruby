The Hy re-speller renamed a Python name that collides with a Hy macro everywhere it was a name, and a class body that read its own method under that name stopped loading.

Hy treats the head of a call that names one of its core macros as that macro, so `fn(x)`, `get(k)` or `when(t)`
cannot be spelled `(fn x)`, `(get k)` or `(when t)`; `tools/cs2x/py2hy.py` renames such names (`get` becomes
`get__h`) wherever a name is bound or read, and leaves attributes and method names alone (`(.get p i)` is a method
call, not the macro). The first build of the Hy runtime stopped at import:

```
  File "/home/claude/swmm6-ports/hy/cpp/core_ptr.hy", line 82, in CPtr
    (setv get_Item get__h)
                    ^^^^^
NameError: name 'get__h' is not defined
```

`py/cpp/core_ptr.py`:

```python
class CPtr:
    def get(self, i):            # a method: its name stayed get
        ...
    get_Item = get               # a name read in the class body: renamed get__h
```

In Python a name read in a class body is looked up in the class's namespace first, so here `get` is the method just
defined, a class attribute, whose name was (rightly) not changed. The rename had followed the syntax (a Name node)
and not the scope.

The fix: a name that a class body binds directly (its methods, nested classes and assigned names) keeps its spelling
when it is read or written in that body (`class_bound_names`), and the check's normaliser applies the same rule to
Python's tree, so the compile-back comparison would have caught a difference between them. The runtime then loaded
and the check gave 0 differences on all 17 files.

The rule: a renaming pass for a target language must resolve names the way the source language does; a rename
keyed on the node type alone breaks where the source language's scopes are not lexical, as a Python class body is not.
