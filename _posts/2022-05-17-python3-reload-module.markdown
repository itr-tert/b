---
layout: post
title:  "python3 でサブモジュールも reload する"
date: 2022-05-17
---

### 結論コード:

{% highlight python linenos %}
import importlib
import os.path
import sys

# Below function code is released under license "CC0 1.0 Universal" by itr-tert
# https://creativecommons.org/publicdomain/zero/1.0/deed.en
def reload_module_tree(target_module):
    """
    Import a previously imported module and submodules of them anew and return
    it.
    This function considers the directory in which the module is located and
    the modules under it as submodules. Remove those modules from sys.modules
    and execute importlib.import_module for target_module.
    using:
      ex1: globals()["mod1"] = reload_module_tree(mod1)
      ex2: import mod6
           from mod6 import func7
           func8 = mod6.func8
           globals()["mod6"] = reload_module_tree(mod6)
    In the case of ex2, the contents of mod6 are realoded, but func7 and func8
    have older contents(mod6.func7 and mod6.func8 have newer contents).
    """
    target_directory = os.path.dirname(target_module.__file__)
    module_name_list_to_delete = []
    for loaded_module_name in sys.modules:
        loaded_module_self = sys.modules[loaded_module_name]
        if     (not hasattr(loaded_module_self, "__file__")
                or loaded_module_self.__file__ is None
                or not loaded_module_self.__file__.startswith(target_directory)):
            continue
        module_name_list_to_delete.append(loaded_module_name)
    for name in module_name_list_to_delete:
        del sys.modules[name]
    return importlib.import_module(target_module.__name__)
{% endhighlight %}

### 環境:
```
python3 --version: Python 3.8.10
```

### なにが問題か:
`importlib.reload` は引数モジュールのサブモジュールをリロードしない。  
引数指定したモジュールが参照しているサブモジュールもリロードして欲しい。

上記のコードでは引数に指定したモジュールのファイルパスを`.__file__`から得て、そのディレクトリ以下にファイルパスが属しているモジュールを `sys.modules` から削除してから、再びインポートしている。

`sys.modules` から削除することは unload ではないが似た作用を持つ。

この方法は、サブモジュールやサブファイルの増減にも対応している。

(ただ単にロード済みモジュールをリロードするだけでは増減に対応できない。)

### 必要な reload 実装のためのヒント

実際にどのような reload が必要かは、場合によるため一意な解決策はない。

* `import` されたモジュールはキャッシュされる。ふたたび `import` してもモジュール内容は更新されない。そのキャッシュは `sys.modules` にある。

* `importlib.reload`:

  * 指定したモジュール実体そのものを置き換えるかのような挙動をする。
	```
	import mod1
	mod_one = mod1
	importlib.reload(mod1)
	```
	とした場合でも `mod_one` は新しくなっている。

  * しかし、関数やクラスなどオブジェクトに対してはそうではない。
    ```
	import mod1
	func1 = mod1.func1
	importlib.reload(mod1)
	func1()
	```
	この場合に最後に実行される func1 は古い実装のもの。これは`from mod1 import func1`でも同様。(`mod1.func1()` ならば新しいものが実行される)
	
* `built-in module` は `hasattr(built_in_module1, '__file__')` == False

* `__init__.py` がないディレクトリ名に対するインポートは module型の namespace になる(`import dir_name; str(dir_name)` は `<module 'dir_name' (namespace)>`)  
	`namespace module` は `namespace_module1.__file__ is None`

* `__init__.py` があるディレクトリ名に対するインポートだと `import dir_name; dir_name.__file__ == "dir_name/__init.py"`

* `inspect.getfile(obj)` で `obj` が定義されたファイルが分かる。また `inspect.getfile` の定義も参照のこと。

* `globals()` はそれが書かれた場所でのグローバル変数連想配列を返す。  
  これの要素の書き換えは反映される。

* `locals()` はそれが書かれた場所でのローカル変数連数配列を返す。  
  これを書き換えても反映されない。

* see also: `IPython.lib.deepreload.reload`
