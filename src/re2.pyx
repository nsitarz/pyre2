# cython: infer_types(False)
# Import re flags to be compatible.
import sys
import re
import sre_parse
import sre_constants

I = re.I
IGNORECASE = re.IGNORECASE
M = re.M
MULTILINE = re.MULTILINE
S = re.S
DOTALL = re.DOTALL
U = re.U
UNICODE = re.UNICODE
X = re.X
VERBOSE = re.VERBOSE
L = re.L
LOCALE = re.LOCALE

FALLBACK_QUIETLY = 0
FALLBACK_WARNING = 1
FALLBACK_EXCEPTION = 2

VERSION = (0, 2, 13)
VERSION_HEX = 0x00020D

# Type of compiled re object from Python stdlib
SREPattern = type(re.compile(''))

cdef int current_notification = FALLBACK_QUIETLY

def set_fallback_notification(level):
    """
    Set the fallback notification to a level; one of:
        FALLBACK_QUIETLY
	FALLBACK_WARNING
	FALLBACK_EXCEPTION
    """
    global current_notification
    level = int(level)
    if level < 0 or level > 2:
        raise ValueError("This function expects a valid notification level.")
    current_notification = level


class RegexError(re.error):
    """
    Some error has occured in compilation of the regex.
    """
    pass

error = RegexError

cdef int _I = I, _M = M, _S = S, _U = U, _X = X, _L = L

cimport _re2
cimport cpython.unicode
from cython.operator cimport preincrement as inc, dereference as deref
import warnings

cdef object cpp_to_pystring(_re2.cpp_string input):
    # This function is a quick converter from a std::string object
    # to a python string. By taking the slice we go to the right size,
    # despite spurious or missing null characters.
    return input.c_str()[:input.length()]

cdef inline object cpp_to_utf8(_re2.cpp_string input):
    # This function converts a std::string object to a utf8 object.
    return cpython.unicode.PyUnicode_DecodeUTF8(input.c_str(), input.length(), 'strict')

cdef inline object char_to_utf8(_re2.const_char_ptr input, int length):
    # This function converts a C string to a utf8 object.
    return cpython.unicode.PyUnicode_DecodeUTF8(input, length, 'strict')

cdef inline object unicode_to_bytestring(object pystring, int * encoded):
    # This function will convert a utf8 string to a bytestring object.
    if cpython.unicode.PyUnicode_Check(pystring):
        pystring = cpython.unicode.PyUnicode_EncodeUTF8(cpython.unicode.PyUnicode_AS_UNICODE(pystring),
                                                       cpython.unicode.PyUnicode_GET_SIZE(pystring),
                                                       "strict")
        encoded[0] = 1
    else:
        encoded[0] = 0
    return pystring

cdef inline int pystring_to_bytestring(object pystring, char ** cstring, Py_ssize_t * length):
    # This function will convert a pystring to a bytesstring, placing
    # the char * in cstring, and the length in length.
    # First it will try treating it as a str object, but failing that
    # it will move to utf-8. If utf8 does not work, then it has to be
    # a non-supported encoding.
    return _re2.PyObject_AsCharBuffer(pystring, <_re2.const_char_ptr*> cstring, length)

cdef extern from *:
    cdef void emit_ifndef_py_unicode_wide "#if !defined(Py_UNICODE_WIDE) //" ()
    cdef void emit_endif "#endif //" ()


# String position map directions
BYTE_TO_UNICODE = 0
UNICODE_TO_BYTE = 1

cpdef dict string_position_map(object match_string, object positions, int dir ):
    cdef char* s = match_string 
    cdef int cpos = 0
    cdef int upos = 0
    cdef int size = len(match_string)
    cdef int c
    cdef dict new_positions = {}
    cdef int i = 0
    cdef int num_positions = len(positions)

    positions = sorted(positions)

    if positions[i] == -1:
        new_positions[-1] = -1
        inc(i)
        if i == num_positions:
            return new_positions
    if positions[i] == 0:
        new_positions[0] = 0
        inc(i)
        if i == num_positions:
            return new_positions

    while cpos < size:
        c = <unsigned char>s[cpos]
        if c < 0x80:
            inc(cpos)
            inc(upos)
        elif c < 0xe0:
            cpos += 2
            inc(upos)
        elif c < 0xf0:
            cpos += 3
            inc(upos)
        else:
            cpos += 4
            inc(upos)
            # wide unicode chars get 2 unichars when python is compiled with --enable-unicode=ucs2
            # TODO: verify this
            emit_ifndef_py_unicode_wide()
            inc(upos)
            emit_endif()

        if positions[i] == cpos and dir == BYTE_TO_UNICODE:
            new_positions[positions[i]] = upos
            inc(i)
            if i == num_positions:
                return new_positions

        elif positions[i] == upos and dir == UNICODE_TO_BYTE:
            new_positions[positions[i]] = cpos
            inc(i)
            if i == num_positions:
                return new_positions

    assert False, "Not all positions were converted"

cdef class Match:
    cdef _re2.StringPiece * matches
    cdef _re2.const_stringintmap * named_groups

    cdef bint encoded
    cdef int _lastindex
    cdef int nmatches
    cdef int _pos
    cdef int _endpos
    cdef object match_string
    cdef object _pattern_object
    cdef tuple _groups
    cdef tuple _spans
    cdef dict _named_groups
    cdef dict _named_indexes

    def __init__(self, object pattern_object, int num_groups):
        self._lastindex = -1
        self._groups = None
        self._pos = 0
        self._endpos = -1
        self.matches = _re2.new_StringPiece_array(num_groups + 1)
        self.nmatches = num_groups
        self._pattern_object = pattern_object

    def __dealloc__(self):
        _re2.delete_StringPiece_array(self.matches)

    property re:
        def __get__(self):
            return self._pattern_object

    property pos:
        def __get__(self):
            return self._pos

    property endpos:
        def __get__(self):
            return self._endpos

    property string:
        def __get__(self):
            return self.match_string

    cdef init_groups(self):
        cdef list groups = []
        cdef int i
        cdef bint cur_encoded = self.encoded

        if self._groups is not None:
            return

        cdef _re2.const_char_ptr last_end = NULL
        cdef _re2.const_char_ptr cur_end = NULL

        for i in range(self.nmatches):
            if self.matches[i].data() == NULL:
                groups.append(None)
            else:
                if i > 0:
                    cur_end = self.matches[i].data() + self.matches[i].length()

                    if last_end == NULL:
                        last_end = cur_end
                        self._lastindex = i
                    else:
                        # The rules for last group are a bit complicated:
                        # if two groups end at the same point, the earlier one is considered last
                        # so we don't switch our selection unless the end point has moved
                        if cur_end > last_end:
                            last_end = cur_end
                            self._lastindex = i

                if cur_encoded:
                    groups.append(char_to_utf8(self.matches[i].data(), self.matches[i].length()))
                else:
                    groups.append(self.matches[i].data()[:self.matches[i].length()])
        self._groups = tuple(groups)

    def groups(self, default=None):
        self.init_groups()
        if default is not None:
            return tuple([g or default for g in self._groups[1:]])
        return self._groups[1:]

    def group(self, *args):
        if len(args) > 1:
            return tuple([self.group(i) for i in args])
        elif len(args) > 0:
            groupnum = args[0]
        else:
            groupnum = 0

        cdef int idx

        self.init_groups()

        if isinstance(groupnum, basestring):
            return self.groupdict()[groupnum]

        idx = groupnum

        if idx > self.nmatches - 1:
            raise IndexError("no such group")
        return self._groups[idx]
    
    cdef object _convert_positions(self, positions):
        cdef char * s = self.match_string
        cdef int cpos = 0
        cdef int upos = 0
        cdef int size = len(self.match_string)
        cdef int c 
        
        new_positions = []
        i = 0
        num_positions = len(positions)
        if positions[i] == -1:
            new_positions.append(-1)
            inc(i)
            if i == num_positions:
                return new_positions
        if positions[i] == 0:
            new_positions.append(0)
            inc(i)
            if i == num_positions:
                return new_positions

        while cpos < size:
            c = <unsigned char>s[cpos]
            if c < 0x80:
                inc(cpos)
                inc(upos)
            elif c < 0xe0:
                cpos += 2
                inc(upos)
            elif c < 0xf0:
                cpos += 3
                inc(upos)
            else:
                cpos += 4
                inc(upos)
                # wide unicode chars get 2 unichars when python is compiled with --enable-unicode=ucs2
                # TODO: verify this
                emit_ifndef_py_unicode_wide()
                inc(upos)
                emit_endif()

            if positions[i] == cpos:
                new_positions.append(upos)
                inc(i)
                if i == num_positions:
                    return new_positions

    def _convert_spans(self, spans):
        positions = [x for x,y in spans] + [y for x,y in spans]
        positions = sorted(set(positions))
        posdict = dict(zip(positions, self._convert_positions(positions)))

        return [(posdict[x], posdict[y]) for x,y in spans]
        

    cdef _make_spans(self):
        if self._spans is not None:
            return

        cdef int start, end
        cdef char * s = self.match_string
        cdef _re2.StringPiece * piece

        spans = []
        for i in range(self.nmatches):
            if self.matches[i].data() == NULL:
                spans.append((-1, -1))
            else:
                piece = &self.matches[i]
                if piece.data() == NULL:
                    return (-1, -1)
                start = piece.data() - s
                end = start + piece.length()
                spans.append((start, end))
        
        if self.encoded:
            spans = self._convert_spans(spans)

        self._spans = tuple(spans)

    property regs:
        def __get__(self):
            if self._spans is None:
                self._make_spans()
            return self._spans

    def expand(self, object template):
        # TODO - This can be optimized to work a bit faster in C.
        # Expand a template with groups
        items = template.split('\\')
        for i, item in enumerate(items[1:]):
            if item[0].isdigit():
                # Number group
                if item[0] == '0':
                    items[i + 1] = '\x00' + item[1:]
                else:
                    items[i + 1] = self.group(int(item[0])) + item[1:]
            elif item[:2] == 'g<' and '>' in item:
                # This is a named group
                name, rest = item[2:].split('>', 1)
                items[i + 1] = self.group(name) + rest
            else:
                # This isn't a template at all
                items[i + 1] = '\\' + item
        return ''.join(items)

    def groupdict(self):
        cdef _re2.stringintmapiterator it
        cdef dict result = {}
        cdef dict indexes = {}

        self.init_groups()

        if self._named_groups:
            return self._named_groups

        self._named_groups = result
        it = self.named_groups.begin()
        while it != self.named_groups.end():
            indexes[cpp_to_pystring(deref(it).first)] = deref(it).second
            result[cpp_to_pystring(deref(it).first)] = self._groups[deref(it).second]
            inc(it)

        self._named_groups = result
        self._named_indexes = indexes
        return result

    def end(self, group=0):
        return self.span(group)[1]

    def start(self, group=0):
        return self.span(group)[0]

    def span(self, group=0):
        self._make_spans()
        if type(group) is int:
            if group > len(self._spans):
                raise IndexError("no such group")
            return self._spans[group]
        else:
            self.groupdict()
            if group not in self._named_indexes:
                raise IndexError("no such group")
            return self._spans[self._named_indexes[group]]


    property lastindex:
        def __get__(self):
            self.init_groups()
            if self._lastindex < 1:
                return None
            else:
                return self._lastindex

    property lastgroup:
        def __get__(self):
            self.init_groups()
            cdef _re2.stringintmapiterator it

            if self._lastindex < 1:
                return None
            
            it = self.named_groups.begin()
            while it != self.named_groups.end():
                if deref(it).second == self._lastindex:
                    return cpp_to_pystring(deref(it).first)
                inc(it)
            
            return None

cdef class Pattern:
    cdef _re2.RE2 * re_pattern
    cdef int ngroups
    cdef bint encoded
    cdef int _flags
    cdef public object pattern
    cdef object __weakref__

    property flags:
        def __get__(self):
            return self._flags

    property groups:
        def __get__(self):
            return self.ngroups

    def __dealloc__(self):
        del self.re_pattern

    cdef _search(self, string, int pos, int endpos, _re2.re2_Anchor anchoring):
        """
        Scan through string looking for a match, and return a corresponding
        Match instance. Return None if no position in the string matches.
        """
        cdef Py_ssize_t size
        cdef int result
        cdef char * cstring
        cdef int encoded = 0
        cdef _re2.StringPiece * sp
        cdef Match m = Match(self, self.ngroups + 1)

        if hasattr(string, 'tostring'):
            string = string.tostring()
        string = unicode_to_bytestring(string, &encoded)
        if pystring_to_bytestring(string, &cstring, &size) == -1:
            raise TypeError("expected string or buffer")

        if endpos != -1 and endpos < size:
            size = endpos

        sp = new _re2.StringPiece(cstring, size)
        with nogil:
            result = self.re_pattern.Match(sp[0], <int>pos, <int>size, anchoring, m.matches, self.ngroups + 1)

        del sp
        if result == 0:
            return None
        m.encoded = <bint>(encoded)
        m.named_groups = _re2.addressof(self.re_pattern.NamedCapturingGroups())
        m.nmatches = self.ngroups + 1
        m.match_string = string
        m._pos = pos
        if endpos == -1:
            m._endpos = len(string)
        else:
            m._endpos = endpos
        return m


    def search(self, string, int pos=0, int endpos=-1):
        """
        Scan through string looking for a match, and return a corresponding
        Match instance. Return None if no position in the string matches.
        """
        return self._search(string, pos, endpos, _re2.UNANCHORED)


    def match(self, string, int pos=0, int endpos=-1):
        """
        Matches zero or more characters at the beginning of the string.
        """
        return self._search(string, pos, endpos, _re2.ANCHOR_START)

    cdef _print_pattern(self):
        cdef _re2.cpp_string * s
        s = <_re2.cpp_string *>_re2.addressofs(self.re_pattern.pattern())
        print cpp_to_pystring(s[0]) + "\n"
        sys.stdout.flush()

    def finditer(self, object string, int pos=0, int endpos=-1):
        """
        Return all non-overlapping matches of pattern in string as a list
        of match objects.
        """
        return MatchIterator(self, string, pos, endpos, 0)

    def findall(self, object string, int pos=0, int endpos=-1):
        """
        Return all non-overlapping matches of pattern in string as a list
        of strings.
        """
        return list(MatchIterator(self, string, pos, endpos, 1))

    def split(self, string, int maxsplit=0):
        """
        split(string[, maxsplit = 0]) --> list
        Split a string by the occurances of the pattern.
        """
        cdef Py_ssize_t size
        cdef int num_groups = 1
        cdef int result
        cdef int endpos
        cdef int pos = 0
        cdef int lookahead = 0
        cdef int num_split = 0
        cdef char * cstring
        cdef _re2.StringPiece * sp
        cdef _re2.StringPiece * matches
        cdef Match m
        cdef list resultlist = []
        cdef int encoded = 0
        
        if maxsplit < 0:
            maxsplit = 0
        
        string = unicode_to_bytestring(string, &encoded)
        if pystring_to_bytestring(string, &cstring, &size) == -1:
            raise TypeError("expected string or buffer")
        
        encoded = <bint>encoded
        
        matches = _re2.new_StringPiece_array(self.ngroups + 1)
        sp = new _re2.StringPiece(cstring, size)
        
        while True:
            with nogil:
                result = self.re_pattern.Match(sp[0], <int>(pos + lookahead), <int>size, _re2.UNANCHORED, matches, self.ngroups + 1)
            if result == 0:
                break
        
            match_start = matches[0].data() - cstring
            match_end = match_start + matches[0].length()
        
            # If an empty match, just look ahead until you find something
            if match_start == match_end:
                if pos + lookahead == size:
                    break
                lookahead += 1
                continue
        
            if encoded:
                resultlist.append(char_to_utf8(<_re2.const_char_ptr>&sp.data()[pos], match_start - pos))
            else:
                resultlist.append(sp.data()[pos:match_start])
            if self.ngroups > 0:
                for group in range(self.ngroups):
                    if matches[group + 1].data() == NULL:
                        resultlist.append(None)
                    else:
                        if encoded:
                            resultlist.append(char_to_utf8(matches[group + 1].data(), matches[group + 1].length()))
                        else:
                            resultlist.append(matches[group + 1].data()[:matches[group + 1].length()])
        
            # offset the pos to move to the next point
            pos = match_end
            lookahead = 0
        
            num_split += 1
            if maxsplit and num_split >= maxsplit:
                break
        
        if encoded:
            resultlist.append(char_to_utf8(<_re2.const_char_ptr>&sp.data()[pos], sp.length() - pos))
        else:
            resultlist.append(sp.data()[pos:])
        _re2.delete_StringPiece_array(matches)
        del sp
        return resultlist

    def sub(self, repl, string, int count=0):
        """
        sub(repl, string[, count = 0]) --> newstring
        Return the string obtained by replacing the leftmost non-overlapping
        occurrences of pattern in string by the replacement repl.
        """
        return self.subn(repl, string, count)[0]

    def subn(self, repl, string, int count=0):
        """
        subn(repl, string[, count = 0]) --> (newstring, number of subs)
        Return the tuple (new_string, number_of_subs_made) found by replacing
        the leftmost non-overlapping occurrences of pattern with the
        replacement repl.
        """
        cdef Py_ssize_t size
        cdef char * cstring
        cdef _re2.cpp_string * fixed_repl
        cdef _re2.StringPiece * sp
        cdef _re2.cpp_string * input_str
        cdef total_replacements = 0
        cdef int string_encoded = 0
        cdef int repl_encoded = 0
        cdef int encoded = 0

        if callable(repl):
            # This is a callback, so let's use the custom function
            return self._subn_callback(repl, string, count)

        string = unicode_to_bytestring(string, &string_encoded)
        repl = unicode_to_bytestring(repl, &repl_encoded)
        if pystring_to_bytestring(repl, &cstring, &size) == -1:
            raise TypeError("expected string or buffer")

        fixed_repl = NULL
        cdef _re2.const_char_ptr s = cstring
        cdef _re2.const_char_ptr end = s + size
        cdef int c = 0
        while s < end:
            c = s[0]
            if (c == '\\'):
                s += 1
                if s == end:
                    raise RegexError("Invalid rewrite pattern")
                c = s[0]
                if c == '\\' or (c >= '0' and c <= '9'):
                    if fixed_repl != NULL:
                        fixed_repl.push_back('\\')
                        fixed_repl.push_back(c)
                else:
                    if fixed_repl == NULL:
                        fixed_repl = new _re2.cpp_string(cstring, s - cstring - 1)
                    if c == 'n':
                        fixed_repl.push_back('\n')   
                    else:
                        fixed_repl.push_back('\\')
                        fixed_repl.push_back('\\')
                        fixed_repl.push_back(c)
            else:
                if fixed_repl != NULL:
                    fixed_repl.push_back(c)

            s += 1
        if fixed_repl != NULL:
            sp = new _re2.StringPiece(fixed_repl.c_str())
        else:
            sp = new _re2.StringPiece(cstring, size)
        
        input_str = new _re2.cpp_string(string)
        if not count:
            total_replacements = _re2.pattern_GlobalReplace(input_str,
                                                            self.re_pattern[0],
                                                            sp[0])
        elif count == 1:
            total_replacements = _re2.pattern_Replace(input_str,
                                                      self.re_pattern[0],
                                                      sp[0])
        else:
            del fixed_repl
            del input_str
            del sp
            raise NotImplementedError("So far pyre2 does not support custom replacement counts")

        if string_encoded or (repl_encoded and total_replacements > 0):
            result = cpp_to_utf8(input_str[0])
        else:
            result = cpp_to_pystring(input_str[0])
        del fixed_repl
        del input_str
        del sp
        return (result, total_replacements)

    def _subn_callback(self, callback, string, int count=0):
        """
        This function is probably the hardest to implement correctly.
        This is my first attempt, but if anybody has a better solution, please help out.
        """
        cdef Py_ssize_t size
        cdef int result
        cdef int endpos
        cdef int pos = 0
        cdef int encoded = 0
        cdef int num_repl = 0
        cdef char * cstring
        cdef _re2.StringPiece * sp
        cdef Match m
        cdef list resultlist = []

        if count < 0:
            count = 0

        string = unicode_to_bytestring(string, &encoded)
        if pystring_to_bytestring(string, &cstring, &size) == -1:
            raise TypeError("expected string or buffer")
        encoded = <bint>encoded

        sp = new _re2.StringPiece(cstring, size)

        try:
            while True:
                m = Match(self, self.ngroups + 1)
                with nogil:
                    result = self.re_pattern.Match(sp[0], <int>pos, <int>size, _re2.UNANCHORED, m.matches, self.ngroups + 1)
                if result == 0:
                    break

                endpos = m.matches[0].data() - cstring
                if encoded:
                    resultlist.append(char_to_utf8(&sp.data()[pos], endpos - pos))
                else:
                    resultlist.append(sp.data()[pos:endpos])
                pos = endpos + m.matches[0].length()

                m.encoded = encoded
                m.named_groups = _re2.addressof(self.re_pattern.NamedCapturingGroups())
                m.nmatches = self.ngroups + 1
                m.match_string = string
                resultlist.append(callback(m) or '')

                num_repl += 1
                if count and num_repl >= count:
                    break

            if encoded:
                resultlist.append(char_to_utf8(&sp.data()[pos], sp.length() - pos))
                return (u''.join(resultlist), num_repl)
            else:
                resultlist.append(sp.data()[pos:])
                return (''.join(resultlist), num_repl)
        finally:
            del sp

cdef class MatchIterator:
    cdef Pattern pattern
    cdef object bytestring
    cdef int pos
    cdef int endpos
    cdef bint as_match
    cdef Py_ssize_t size
    cdef char * cstring
    cdef _re2.StringPiece * sp
    cdef bint encoded 

    def __init__(self, Pattern pattern,  object string, int pos=0, int endpos=-1, int as_match=0):
        self.pattern = pattern
        self.as_match = as_match
        
        self.bytestring = unicode_to_bytestring(string, &self.encoded)
        if pystring_to_bytestring(self.bytestring, &self.cstring, &self.size) == -1:
            raise TypeError("expected string or buffer")
        
        if self.encoded:
            encoded_positions = string_position_map(self.cstring, (pos, endpos), UNICODE_TO_BYTE)
            self.pos = encoded_positions[pos]
            self.endpos = encoded_positions[endpos]
        else:
            self.pos = pos
            self.endpos = endpos
        
        if self.endpos != -1 and self.endpos < self.size:
            self.size = self.endpos

        self.sp = new _re2.StringPiece(self.cstring, self.size)
        
    
    def __dealloc__(self):
        del self.sp
    
    def __iter__(self):
        return self
    
    def __next__(self):
        cdef Match m
        cdef int result
        
        if self.pos > self.size:
            raise StopIteration()
        
        m = Match(self.pattern, self.pattern.ngroups + 1)
        with nogil:
            result = self.pattern.re_pattern.Match(self.sp[0], self.pos, self.size, _re2.UNANCHORED, m.matches, self.pattern.ngroups + 1)
        if result == 0:
            raise StopIteration()
            
        m.encoded = self.encoded
        m.named_groups = _re2.addressof(self.pattern.re_pattern.NamedCapturingGroups())
        m.nmatches = self.pattern.ngroups + 1
        m.match_string = self.bytestring
        m._pos = self.pos
        
        if self.endpos == -1:
            m._endpos = self.size
        else:
            m._endpos = self.endpos
        
        # offset the pos to move to the next point
        if m.matches[0].length() == 0:
            self.pos += 1
        else:
            self.pos = m.matches[0].data() - self.cstring + m.matches[0].length()
        
        if self.as_match:
            if self.pattern.ngroups > 1:
                return m.groups("")
            else:
                return m.group(self.pattern.ngroups)
        else:
            return m


_cache = {}
_cache_repl = {}

_MAXCACHE = 100

def compile(pattern, int flags=0, int max_mem=8388608):
    cachekey = (type(pattern),) + (pattern, flags)
    p = _cache.get(cachekey)
    if p is not None:
        return p
    p = _compile(pattern, flags, max_mem)

    if len(_cache) >= _MAXCACHE:
        _cache.clear()
    _cache[cachekey] = p
    return p

class UnsupportedOpcode(Exception):
    pass

class BackreferencesException(UnsupportedOpcode):
    pass


cpdef object prepare_pattern(object pattern_string, int flags):
    cdef list new_pattern = []
    
    try:
        pattern_list = sre_parse.parse(pattern_string, flags & VERBOSE)
    except sre_parse.error, e:
        raise RegexError(e)
        
    pattern = pattern_list.pattern
    pattern.reverse_groupdict = dict(zip(pattern.groupdict.values(), pattern.groupdict.keys()))
    pattern.is_unicode = type(pattern_string) == unicode
    
    #Check for flags set in the pattern string
    flags = flags | pattern.flags
    
    cdef str strflags = ''
    if flags & _S:
        strflags += 's'
    if flags & _M:
        strflags += 'm'
    if flags & _I:
        strflags += 'i'

    if strflags:
        new_pattern.append('(?' + strflags + ')')
    
    for opcode, arg in pattern_list:
        new_pattern.extend(handle_op(pattern, opcode, arg, flags))
    
    result = "".join(new_pattern)
    
    if pattern.is_unicode:
        return unicode(result)
    else:
        return result
        
cdef list handle_op(object pattern, object opcode, object arg, int flags):
    cdef list new_pattern = []
    
    if opcode == sre_constants.LITERAL:
        if pattern.is_unicode:
            new_pattern.append(unichr(arg))
        else:
            new_pattern.append(chr(arg))
    elif opcode == sre_constants.NOT_LITERAL:
        new_pattern.append(r'[^')
        if pattern.is_unicode:
            new_pattern.append(unichr(arg))
        else:
            new_pattern.append(chr(arg))
        new_pattern.append(r']')
    elif opcode == sre_constants.NEGATE:
        new_pattern.append(r'^')
    elif opcode == sre_constants.RANGE:
        if pattern.is_unicode:
            new_pattern.append(unichr(arg[0]))
            new_pattern.append('-')
            new_pattern.append(unichr(arg[1]))
        else:
            new_pattern.append(chr(arg[0]))
            new_pattern.append('-')
            new_pattern.append(chr(arg[1]))
    elif opcode in (sre_constants.MIN_REPEAT, sre_constants.MAX_REPEAT):
        new_pattern.extend(handle_repeat(pattern, opcode, arg, flags))
    elif opcode == sre_constants.SUBPATTERN:
        new_pattern.extend(handle_subpattern(pattern, arg, flags))
    elif opcode in (sre_constants.ANY, sre_constants.ANY_ALL):
        new_pattern.append('.')
    elif opcode == sre_constants.AT:
        new_pattern.extend(handle_at(pattern, arg, flags))
    elif opcode == sre_constants.CATEGORY:
        new_pattern.extend(handle_category(pattern, arg, flags))
    elif opcode == sre_constants.IN:
        new_pattern.extend(handle_in(pattern, arg, flags))
    elif opcode == sre_constants.BRANCH:
        new_pattern.extend(handle_branch(pattern, arg, flags))
    else:
        raise UnsupportedOpcode, "Opcode %s not implemented" % opcode
    return new_pattern

cdef list handle_branch(object pattern, object arg, int flags):
    cdef list new_pattern = []
    cdef object alt = None
    cdef object alts = arg[1]
    cdef object repeat_opcode = None
    cdef int len_alts = len(alts)
    cdef int n
    
    for n, alt in enumerate(alts):
        if len(alt) == 0:
            continue
        
        #Check for branch prefix optimizations
        if n > 0 and len(alts[n-1]) == 0:
            repeat_opcode = sre_constants.MIN_REPEAT
        elif n + 1 < len_alts and len(alts[n+1]) == 0:
            repeat_opcode = sre_constants.MAX_REPEAT
        
        if repeat_opcode is None:
            for subop, subarg in alt:
                new_pattern.extend(handle_op(pattern, subop, subarg, flags))
        else:
            repeat_arg = (0, 1, [(sre_constants.SUBPATTERN, (None, alt))])
            new_pattern.extend(handle_repeat(pattern, repeat_opcode, repeat_arg, flags))
            
        new_pattern.append(r'|')
    return new_pattern[0:-1]

cdef list handle_repeat(object pattern, object opcode, object arg, int flags):
    cdef list new_pattern = []
    
    cdef int min
    cdef int max
    cdef object subpat
    min, max, subpat = arg
    
    for subop, subarg in subpat:
        new_pattern.extend(handle_op(pattern, subop, subarg, flags))
    if min == 0 and max == 1:
        new_pattern.append(r'?')
    elif min == 0 and max == sre_constants.MAXREPEAT:
        new_pattern.append(r'*')
    elif min == 1 and max == sre_constants.MAXREPEAT:
        new_pattern.append(r'+')
    else:
        new_pattern.append(r'{%d,%d}' % (min, max))
    
    if opcode == sre_constants.MIN_REPEAT:
        new_pattern.append(r'?')
    
    return new_pattern
    

cdef list handle_subpattern(object pattern, object arg, int flags):
    cdef list new_pattern = []
    groupnum, subargs = arg
    
    #Group opening token
    new_pattern.append('(')
    
    #No groupnum implies that its a non-capturing group
    if groupnum is None:
        new_pattern.append('?:')
    else:    
        #Check if the capture group is named
        try:
            name = pattern.reverse_groupdict[groupnum]
        except KeyError:
            pass
        else:
            new_pattern.append(r'?P<')
            new_pattern.append(name)
            new_pattern.append(r'>')
    
    #Handle the args inside the capture group
    for opcode, subarg in subargs:
        new_pattern.extend(handle_op(pattern, opcode, subarg, flags))
        
    #Group closing token
    new_pattern.append(')')
    return new_pattern
    
cdef list handle_at(object pattern, object arg, int flags):
    cdef list new_pattern = []
    emit = new_pattern.append
    if arg in (sre_constants.AT_END_STRING, sre_constants.AT_END_LINE):
        emit(r'\z')
    elif arg == sre_constants.AT_END:
        emit(r'$')
    elif arg == sre_constants.AT_BEGINNING_STRING:
        emit(r'\A')
    elif arg in (sre_constants.AT_BEGINNING, sre_constants.AT_BEGINNING_LINE):
        emit(r'^')
    elif arg == sre_constants.AT_BOUNDARY:
        emit(r'\b')
    elif arg == sre_constants.AT_NON_BOUNDARY:
        emit(r'\B')
    else:
        assert False, "Unsupported AT: " + arg
    return new_pattern
        
cdef list handle_category(object pattern, object arg, int flags):
    cdef list new_pattern = []
    emit = new_pattern.append
    
    if arg == sre_constants.CATEGORY_WORD:
        if flags & _U:
            emit(r'_\p{L}\p{Nd}')
        else:
            emit(r'\w')
    elif arg == sre_constants.CATEGORY_NOT_WORD:
        if flags & _U:
            emit(r'^_\p{L}\p{Nd}')
        else:
            emit(r'\W')
    elif arg == sre_constants.CATEGORY_DIGIT:
        if flags & _U:
            emit(r'\p{Nd}')
        else:
            emit(r'\d')
    elif arg == sre_constants.CATEGORY_NOT_DIGIT:
        if flags & _U:
            emit(r'\P{Nd}')
        else:
            emit(r'\D')
    elif arg == sre_constants.CATEGORY_SPACE:
        if flags & _U:
            emit(r'\s\p{Z}')
        else:
            emit(r'\s')
    elif arg == sre_constants.CATEGORY_NOT_SPACE:
        if flags & _U:
            emit(r'\S\P{Z}')
        else:
            emit(r'\S')
    else:
        assert False, "Category %s not implemented" % arg
    
    return new_pattern

cdef list handle_in(object pattern, object arg, int flags):
    cdef list new_pattern = []
    new_pattern.append('[')
    for opcode, subarg in arg:
        new_pattern.extend(handle_op(pattern, opcode, subarg, flags))
    new_pattern.append(']')
    return new_pattern
    

def _compile(pattern, int flags=0, int max_mem=8388608):
    """
    Compile a regular expression pattern, returning a pattern object.
    """
    cdef char * string
    cdef Py_ssize_t length
    cdef _re2.StringPiece * s
    cdef _re2.Options opts
    cdef int error_code
    cdef int encoded = 0

    if isinstance(pattern, (Pattern, SREPattern)):
        if flags:
            raise ValueError('Cannot process flags argument with a compiled pattern')
        return pattern

    cdef object original_pattern = pattern
    try:
        pattern = prepare_pattern(original_pattern, flags)
    except UnsupportedOpcode:
        error_msg = "Unsupported Opcode"
        if current_notification == <int>FALLBACK_EXCEPTION:
            # Raise an exception regardless of the type of error.
            raise RegexError(error_msg)
        elif current_notification == <int>FALLBACK_WARNING:
            warnings.warn("WARNING: Using re module. Reason: %s" % error_msg)
        return re.compile(original_pattern, flags)

    opts.set_max_mem(max_mem)
    opts.set_log_errors(0)
    opts.set_encoding(_re2.EncodingUTF8)

    # We use this function to get the proper length of the string.

    pattern = unicode_to_bytestring(pattern, &encoded)
    if pystring_to_bytestring(pattern, &string, &length) == -1:
        raise TypeError("first argument must be a string or compiled pattern")

    s = new _re2.StringPiece(string, length)

    cdef _re2.RE2 * re_pattern = new _re2.RE2(s[0], opts)
    if not re_pattern.ok():
        # Something went wrong with the compilation.
        del s
        error_msg = cpp_to_pystring(re_pattern.error())
        error_code = re_pattern.error_code()
        del re_pattern
        if current_notification == <int>FALLBACK_EXCEPTION:
            # Raise an exception regardless of the type of error.
            raise RegexError(error_msg)
        elif error_code not in (_re2.ErrorBadPerlOp, _re2.ErrorRepeatSize,
                                _re2.ErrorBadEscape):
            # Raise an error because these will not be fixed by using the 
            # ``re`` module.
            raise RegexError(error_msg)
        elif current_notification == <int>FALLBACK_WARNING:
            warnings.warn("WARNING: Using re module. Reason: %s" % error_msg)
        return re.compile(original_pattern, flags)

    cdef Pattern pypattern = Pattern()
    pypattern.pattern = original_pattern
    pypattern.re_pattern = re_pattern
    pypattern.ngroups = re_pattern.NumberOfCapturingGroups()
    pypattern.encoded = <bint>encoded
    pypattern._flags = flags
    del s
    return pypattern

def search(pattern, string, int flags=0):
    """
    Scan through string looking for a match to the pattern, returning
    a match object or none if no match was found.
    """
    return compile(pattern, flags).search(string)

def match(pattern, string, int flags=0):
    """
    Try to apply the pattern at the start of the string, returning
    a match object, or None if no match was found.
    """
    return compile(pattern, flags).match(string)

def finditer(pattern, string, int flags=0):
    """
    Return an list of all non-overlapping matches in the
    string.  For each match, the iterator returns a match object.

    Empty matches are included in the result.
    """
    return compile(pattern, flags).finditer(string)

def findall(pattern, string, int flags=0):
    """
    Return an list of all non-overlapping matches in the
    string.  For each match, the iterator returns a match object.

    Empty matches are included in the result.
    """
    return compile(pattern, flags).findall(string)

def split(pattern, string, int maxsplit=0):
    """
    Split the source string by the occurrences of the pattern,
    returning a list containing the resulting substrings.
    """
    return compile(pattern).split(string, maxsplit)

def sub(pattern, repl, string, int count=0):
    """
    Return the string obtained by replacing the leftmost
    non-overlapping occurrences of the pattern in string by the
    replacement repl.  repl can be either a string or a callable;
    if a string, backslash escapes in it are processed.  If it is
    a callable, it's passed the match object and must return
    a replacement string to be used.
    """
    return compile(pattern).sub(repl, string, count)

def subn(pattern, repl, string, int count=0):
    """
    Return a 2-tuple containing (new_string, number).
    new_string is the string obtained by replacing the leftmost
    non-overlapping occurrences of the pattern in the source
    string by the replacement repl.  number is the number of
    substitutions that were made. repl can be either a string or a
    callable; if a string, backslash escapes in it are processed.
    If it is a callable, it's passed the match object and must
    return a replacement string to be used.
    """
    return compile(pattern).subn(repl, string, count)

_alphanum = {}
for c in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01234567890':
    _alphanum[c] = 1
del c

def escape(pattern):
    "Escape all non-alphanumeric characters in pattern."
    s = list(pattern)
    alphanum = _alphanum
    for i in range(len(pattern)):
        c = pattern[i]
        if ord(c) < 0x80 and c not in alphanum:
            if c == "\000":
                s[i] = "\\000"
            else:
                s[i] = "\\" + c
    return pattern[:0].join(s)

