try:
    import sys
    import os
    import zipfile
    import site
    import shutil
    import sysconfig
    
    site.USER_SITE = None
    
    pypath = os.path.expanduser("~/Documents/lib/python3.10/site-packages")
    stdlib = os.path.join(os.getenv("APP"), "site-packages", "python3.10")
    sysconfig._INSTALL_SCHEMES["ios"]["stdlib"] = stdlib
    sysconfig._INSTALL_SCHEMES["ios"]["platstdlib"] = stdlib
    sysconfig._INSTALL_SCHEMES["ios"]["platlib"] = pypath
    sysconfig._INSTALL_SCHEMES["ios"]["purelib"] = pypath

    sys.path.insert(-1, site.getusersitepackages())

    if not os.path.isdir(site.getusersitepackages()):
        os.makedirs(site.getusersitepackages(), exist_ok=True)

    old_site_packages = os.path.expanduser("~/Documents/site-packages")
    if os.path.isdir(old_site_packages):
        file_names = os.listdir(old_site_packages)
    
        for file_name in file_names:
            shutil.move(os.path.join(old_site_packages, file_name), site.getusersitepackages())
        
        shutil.rmtree(old_site_packages)

    import io
    import console
    import code
    import pyto
    from importlib.machinery import SourceFileLoader
    import importlib
    import threading
    from time import sleep
    from outputredirector import Reader, InputReader
    from extensionsimporter import *
    import warnings
    import logging
    import webbrowser
    import _sharing as sharing
    import _signal
    import unittest
    from _pip import BUNDLED_MODULES
    from ctypes import CDLL
    from time import sleep
    import collections
    import subprocess
    import runpy
    import mimetypes
    import _ios_popen
    import pydoc
    import _ios_getpass
    import getpass
    from _extensionsimporter import system
    import platform
    import _collections_abc
    
    def with_docstring(object, doc):
        object.__doc__ = doc
        return object
        
    # MARK: - getpass
    
    getpass.getpass = with_docstring(_ios_getpass.getpass, getpass.getpass.__doc__)
    
    # MARK: - MIME types
    
    mimetypes.knownfiles = os.path.join(os.path.dirname(sys.executable), "mime.types")
    
    # MARK: - Help
    
    def help(obj):
        text = pydoc.render_doc(obj, renderer=pydoc.plaintext)
        print(text)
        
    __builtins__.help = with_docstring(help, __builtins__.help.__doc__)
    
    # MARK: - Warnings

    def __send_warnings_to_log__(message, category, filename, lineno, file=None, line=None):

        try:
            warnings
        except:
            import warnings
        
        try:
            pyto
        except:
            import pyto
        
        _message = warnings.formatwarning(message, category, filename, lineno, line)
        
        if "ImportWarning: FullVersionImporter.find_spec()" in _message or "DeprecationWarning: the load_module() method is deprecated" in _message or "DeprecationWarning: PathFinder.find_module() is deprecated" in _message:
            # TODO: Fix those warnings instead of hiding them
            return
        
        # Well I think the next warnings are not my fault
        if "DeprecationWarning: The distutils package is deprecated and slated for removal in Python 3.12." in _message:
            return
        
        if "DeprecationWarning: The distutils.sysconfig module is deprecated, use sysconfig instead" in _message:
            return
            
        if "DeprecationWarning: Creating a LegacyVersion has been deprecated and will be removed in the next major release" in _message:
            return
        
        if "UserWarning: Distutils was imported before Setuptools," in _message:
            return
        
        if "DeprecationWarning: distutils Version classes are deprecated. Use packaging.version instead." in _message:
            return
            
        if "UserWarning: Setuptools is replacing distutils." in _message:
            return
        
        try:
            if category.__name__ == "SetuptoolsDeprecationWarning":
                return
        except AttributeError:
            pass
        
        try:
            pyto.PyOutputHelper.printWarning(_message, script=threading.current_thread().script_path)
        except AttributeError:
            pyto.PyOutputHelper.printWarning(_message, script=None)
        return

    warnings.showwarning = __send_warnings_to_log__
    warnings.filterwarnings("default")

    # MARK: - Subprocesses

    os.allows_subprocesses = True
    subprocess.Popen = with_docstring(_ios_popen.Popen, subprocess.Popen.__doc__)
    
    # MARK: - Per thread chdir
    
    _old_chdir = os.chdir
    
    def chdir(dir):
        path = os.path.realpath(dir)
        if not os.path.isdir(path) or not os.access(path, os.R_OK):
            return _old_chdir(dir)
        
        CDLL(None).pthread_chdir_np(path.encode())
    
    os.chdir = with_docstring(chdir, os.chdir.__doc__)

    # MARK: - Input

    def askForInput(prompt=None):
        try:
            threading
        except NameError:
            import threading

        try:
            console
        except NameError:
            import console

        if (threading.current_thread() in console.ignoredThreads):
            return ""
        else:
            return console.input(prompt)

    __builtins__.input = with_docstring(askForInput, __builtins__.input.__doc__)

    # MARK: - Output

    def read(text):
        try:
            console
        except NameError:
            import console

        console.print(text, end="")

    def write(txt):

        try:
            os
        except NameError:
            import os
        
        try:
            threading
        except NameError:
            import threading

        if ("widget" not in os.environ) and (threading.current_thread() in console.ignoredThreads):
            return
        
        if txt.__class__ is str:
            read(txt)
        elif txt.__class__ is bytes:
            text = txt.decode()
            write(text)

    def read_input(*args):
        return askForInput("")

    standardOutput = Reader(read)
    standardOutput._buffer = io.BufferedWriter(standardOutput)
    standardOutput.buffer.write = write

    standardError = Reader(read)
    standardError._buffer = io.BufferedWriter(standardError)
    standardError.buffer.write = write
    
    standardInput = InputReader()
    standardInput._buffer = io.BufferedReader(standardInput)
    standardInput.buffer.read = read_input

    sys.stdout = with_docstring(standardOutput, sys.stdout.__doc__)
    sys.stderr = with_docstring(standardError, sys.stderr.__doc__)
    sys.stdin = with_docstring(standardInput, sys.stdin.__doc__)
    
    sys.__stdout__ = sys.stdout
    sys.__stderr__ = sys.__stderr__
    sys.__stdin__ = sys.__stdin__

    old_print = __builtins__.print
    def print(*values, sep=None, end=None, file=None, flush=False):
        if file is None:
            file = __import__("sys").stdout
        
        return old_print(*values, sep=sep, end=end, file=file, flush=flush)
    
    __builtins__.print = with_docstring(print, old_print.__doc__)
    
    logging.basicConfig(level=logging.INFO)

    # MARK: - Web browser

    class MobileSafari(webbrowser.BaseBrowser):
        '''
        Mobile Safari web browser.
        '''
        
        def open(self, url, new=0, autoraise=True):
            sharing.open_url(url)
            return True

    webbrowser.register("mobile-safari", None, MobileSafari("MobileSafari.app"))

    # MARK: - Modules

    sys.meta_path.insert(0, FrameworksImporter())
    sys.meta_path.insert(1, BitcodeImporter())

    # MARK: - Pre-import modules

    def importModules():
    
        try:
            import toga_Pyto
        except:
            pass

        try:
            import PIL.ImageShow

            def show_image(image, title=None, **options):
                import os
                import tempfile
                import _sharing as sharing
                import _opencv_view as ocv
                
                if title == "OpenCV":
                    ocv.show(image)
                else:

                    imgPath = tempfile.gettempdir()+"/image.png"

                    i = 1
                    while os.path.isfile(imgPath):
                        i += 1
                        imgPath = os.path.join(tempfile.gettempdir(), 'image '+str(i)+'.png')
            
                    image.save(imgPath, "PNG")
                    
                    sharing.quick_look(imgPath)

            PIL.ImageShow.show = show_image
        
        except:
            pass

    importModules()

    # MARK: - Terminal size
    
    def _get_terminal_size(fallback=(80, 24)):
        try:
            path = threading.current_thread().script_path
        except AttributeError:
            path = None

        size = list(pyto.ConsoleViewController.getTerminalSize(path, fallback=list(fallback)))
        return os.terminal_size((size[0].intValue, size[1].intValue))

    def _os_get_terminal_size(fd=None):
        return _get_terminal_size()
    
    os.get_terminal_size = _os_get_terminal_size
    shutil.get_terminal_size = _get_terminal_size

    # MARK: - Platform
    
    def platform_system():
        return "iOS"
    
    platform.system = platform_system

    # MARK: - Sys
    
    class SysPath(collections.abc.MutableSequence):

        def __init__(self, path):
            self.path = path

        def get_path(self):
            thread = threading.current_thread()
            if "script_path" in dir(thread):
                return sys.modules["sys"].path
            else:
                return self.path

        def __len__(self): return len(self.get_path())

        def __getitem__(self, i): return self.get_path()[i]

        def __delitem__(self, i): del self.get_path()[i]

        def __setitem__(self, i, v):
            self.get_path()[i] = v

        def insert(self, i, v):
            self.get_path().insert(i, v)

        def __str__(self):
            return str(self.get_path())
            
        def copy(self):
            return SysPath(self.path)
    
    class SysArgv(collections.abc.MutableSequence):

        def __init__(self, argv):
            self.argv = argv

        def get_argv(self):
            thread = threading.current_thread()
            if "script_path" in dir(thread):
                return sys.modules["sys"].argv
            else:
                return self.argv

        def __len__(self): return len(self.get_argv())

        def __getitem__(self, i): return self.get_argv()[i]

        def __delitem__(self, i): del self.get_argv()[i]

        def __setitem__(self, i, v):
            self.get_argv()[i] = v

        def insert(self, i, v):
            self.get_argv().insert(i, v)

        def __str__(self):
            return str(self.get_argv())

    
    class Sys(sys.__class__):
    
        instances = {}
        
        main = {}
    
        def __init__(self, sys):
            self.sys = sys
            self.sys.__path__ = self.sys.path
            self.sys.path = SysPath(self.sys.path)
            self.sys.argv = SysArgv(self.sys.argv)
        
        def __dir__(self):
            return dir(self.sys)
        
        __doc__ = sys.__doc__
        
        def setup_properties_if_needed(self, script_path):
            if not script_path in self.__class__.instances:
                path = []
                for location in self.sys.__path__:
                    path.append(location)
                self.__class__.instances[script_path] = {
                    "path": path,
                    "argv": [],
                    "stdout": self.sys.stdout,
                    "stderr": self.sys.stderr,
                    "stdin": self.sys.stdin,
                    "__stdout__": self.sys.stdout,
                    "__stderr__": self.sys.stderr,
                    "__stdin__": self.sys.stdin,
                     "__is_shortcut__": False
                }
        
        def __setattr__(self, attr, value):
            if attr == "sys":
                super().__setattr__(attr, value)
            else:
                thread = threading.current_thread()
        
                if "script_path" in dir(thread):
        
                    self.setup_properties_if_needed(thread.script_path)
        
                    if attr in self.__class__.instances[thread.script_path]:
                        self.__class__.instances[thread.script_path][attr] = value
                        return
            
                setattr(self.sys, attr, value)
        
        def __getattr__(self, attr):
            thread = threading.current_thread()
    
            if "script_path" in dir(thread):
    
                self.setup_properties_if_needed(thread.script_path)
    
                if attr in self.__class__.instances[thread.script_path]:
                    return self.__class__.instances[thread.script_path][attr]
                        
        
            return getattr(self.sys, attr)

    sys.modules["sys"] = Sys(sys)
    console.sys = sys.modules["sys"]
    
    if "__main__" in sys.modules:
        del sys.modules["__main__"]
    
    __import__("__main__")

    # MARK: - Pip bundled modules
    
    # Add modules to `bundled`. I add it one by one because for some reason setting directly an array fails **sometimes**. Seems like something new in iOS 13.5 but I'm not sure.
    for module in BUNDLED_MODULES:
        pyto.PipViewController.addBundledModule(module)


    # MARK: - OS
    
    def getpgid():
        raise OSError()

    def fork():
        pass

    def waitpid(pid, options):
        return (-1, 0)

    os.getpgid = getpgid
    os.fork = fork
    os.waitpid = waitpid
    os._exit = sys.exit
    
    os.system = system

    # MARK: - Handle signal called outside main thread

    old_signal = _signal.signal
    def signal(signal, handler):
        try:
            threading
        except NameError:
            import threading
        
        if threading.main_thread() == threading.current_thread():
            return old_signal(signal, handler)
        else:
            return None
    _signal.signal = signal

    # MARK: - Plugin

    __builtins__.__editor_delegate__ = None

    # MARK: - Unittest

    _original_unittest_main = unittest.main
    def _unittest_main(module='__main__', defaultTest=None, argv=None, testRunner=None, testLoader=unittest.defaultTestLoader, exit=True, verbosity=1, failfast=None, catchbreak=None, buffer=None, warnings=None):

        _module = module
        
        if module == "__main__":
            thread = threading.current_thread()

            try:
                path = thread.script_path
                _module = path.split("/")[-1]
                _module = os.path.splitext(_module)[0]
            except AttributeError:
                pass

        _original_unittest_main(_module, defaultTest, argv, testRunner, testLoader, exit, verbosity, failfast, catchbreak, buffer, warnings)

    unittest.main = _unittest_main

    # MARK: - Run script
    
    def run():
        SourceFileLoader("main", "%@").load_module()
        sleep(0.2)
        CDLL(None).putenv(b"IS_PYTHON_RUNNING=1")

    threading.Thread(target=run).start()

    threading.Event().wait()

except BaseException as e:
    import traceback
    from ctypes import CDLL
    
    s = traceback.format_exc()
    
    CDLL(None).logToNSLog(s.encode())
    CDLL(None).logToNSLog(str(e).encode())
