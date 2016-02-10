﻿module dpq2.answer;

@trusted:

public import dpq2.query;
public import dpq2.types.to_d_types;
public import dpq2.types.to_bson;
import dpq2.oids;

public import derelict.pq.pq;

import derelict.pq.pq;

import core.vararg;
import std.string: toStringz, fromStringz;
import std.exception: enforceEx;
import core.exception: OutOfMemoryError, AssertError;
import std.bitmanip: bigEndianToNative;
import std.typecons: Nullable;

/// Result table's cell coordinates 
struct Coords
{
    size_t row; /// Row
    size_t col; /// Column
}

/// Answer
immutable class Answer
{
    private immutable (PGresult*) res;

    nothrow invariant()
    {
        assert( res != null );
    }
        
    package this(immutable PGresult* r) nothrow immutable
    {
        res = r;
    }
    
    ~this()
    {
        if( res )
        {
            PQclear(res);
        }
        else
            assert( true, "double free!" );
    }
    
    package void checkAnswerForErrors() const
    {
        cast(void) enforceEx!OutOfMemoryError(res, "Can't write query result");

        switch(status)
        {
            case PGRES_COMMAND_OK:
            case PGRES_TUPLES_OK:
                break;

            case PGRES_EMPTY_QUERY:
                throw new AnswerException(ExceptionType.EMPTY_QUERY,
                    "Empty query", __FILE__, __LINE__);

            case PGRES_FATAL_ERROR:
                throw new AnswerException(ExceptionType.FATAL_ERROR,
                    resultErrorMessage, __FILE__, __LINE__);

            default:
                throw new AnswerException(ExceptionType.UNDEFINED_FIXME,
                    "Please report if you came across this error! status="~to!string(status)~"\r\n"~
                    resultErrorMessage, __FILE__, __LINE__);
        }
    }
    
    @property
    ExecStatusType status() const
    {
        return PQresultStatus(res);
    }

    /// Returns the command status tag from the SQL command that generated the PGresult
    /**
     * Commonly this is just the name of the command, but it might include 
     * additional data such as the number of rows processed. The caller should 
     * not free the result directly. It will be freed when the associated 
     * PGresult handle is passed to PQclear.
     */
    @property string cmdStatus() const
    {
        return to!string( PQcmdStatus(res) );
    }

    /// Returns row count
    @property size_t length() const { return PQntuples(res); }

    /// Returns column count
    @property size_t columnCount() const { return PQnfields(res); }

    /// Returns column format
    ValueFormat columnFormat( const size_t colNum ) const
    {
        assertCol( colNum );
        return cast(ValueFormat) PQfformat(res, to!int(colNum));
    }
    
    /// Returns column Oid
    @property OidType OID( size_t colNum ) const
    {
        assertCol( colNum );

        return oid2oidType(PQftype(res, to!int(colNum)));
    }

    @property bool isSupportedArray( const size_t colNum ) const
    {
        assertCol(colNum);

        return dpq2.oids.isSupportedArray(OID(colNum));
    }

    /// Returns column number by field name
    size_t columnNum( string columnName ) const
    {    
        size_t n = PQfnumber(res, toStringz(columnName));

        if( n == -1 )
            throw new AnswerException(ExceptionType.COLUMN_NOT_FOUND,
                    "Column '"~columnName~"' is not found", __FILE__, __LINE__);

        return n;
    }

    /// Returns column name by field number
    string columnName( in size_t colNum ) const
    {
        const char* s = PQfname(cast(PGresult*) res, to!int(colNum)); // FIXME: res should be a const

        if( s == null )
            throw new AnswerException(
                    ExceptionType.OUT_OF_RANGE,
                    "Column "~to!string(colNum)~" is out of range 0.."~to!string(columnCount),
                    __FILE__, __LINE__
                );

        return to!string(fromStringz(s));
    }

    /// Returns row of cells
    immutable (Row) opIndex(in size_t row)
    {
        return immutable Row(
            cast(immutable)(this), // legal because this.ctor is immutable
            row
        );
    }

    @property
    debug string toString() const
    {
        return "Rows: "~to!string(length)~" Columns: "~to!string(columnCount);
    }
    
    @property
    private string resultErrorMessage() const
    {
        return to!string( PQresultErrorMessage(res) );
    }

    @property
    private string resultErrorField(int fieldcode) const
    {
        return to!string( PQresultErrorField(cast(PGresult*)res, fieldcode) ); // FIXME: res should be a const
    }

    private void assertCol( const size_t c ) const
    {
        if(!(c < columnCount))
            throw new AnswerException(
                ExceptionType.OUT_OF_RANGE,
                "Column "~to!string(c)~" is out of range 0.."~to!string(columnCount)~" of result columns",
                __FILE__, __LINE__
            );
    }
    
    private void assertRow( const size_t r ) const
    {
        if(!(r < length))
            throw new AnswerException(
                ExceptionType.OUT_OF_RANGE,
                "Row "~to!string(r)~" is out of range 0.."~to!string(length)~" of result rows",
                __FILE__, __LINE__
            );
    }
    
     private void assertCoords( const Coords c ) const
    {
        assertRow( c.row );
        assertCol( c.col );
    }
}

struct Rangify(T)
{
    immutable T obj;
    alias obj this;

    private int currRow;

    this(T o)
    {
        obj = o;
    }

    @property auto front(){ return obj[currRow]; }
    @property void popFront(){ ++currRow; }
    @property bool empty(){ return currRow >= obj.length; }
}

/// Represents one row from the answer table
immutable struct Row
{
    private immutable Answer answer;
    private immutable size_t row;
    
    this(immutable Answer answer, in size_t row) immutable
    {
        answer.assertRow( row );
        
        this.answer = answer;
        this.row = row;
    }
    
    /// Returns cell size
    @property
    size_t size( const size_t col ) const
    {
        answer.assertCol(col);
        return PQgetlength(answer.res, to!int(row), to!int(col));
    }
    
    /// Value NULL checking
    /// Do not confuse it with Nullable's isNull property
    @property
    bool isNULL( const size_t col ) const
    {
        answer.assertCol(col);

        return PQgetisnull(answer.res, to!int(row), to!int(col)) != 0;
    }

    immutable (Nullable!Value) opIndex(in size_t col)
    {
        answer.assertCoords( Coords( row, col ) );

        auto v = cast(immutable) PQgetvalue(answer.res, to!int(row), to!int(col));
        auto s = size( col );
        
        Nullable!Value r;
        
        if(!isNULL(col))
            r = Value(v, s, answer.columnFormat(col), answer.OID(col));
        
        return cast(immutable) r;
    }
    
    immutable (Nullable!Value) opIndex(in string column) const
    {
        return opIndex(columnNum(column));
    }
    
    /// Returns column number by field name
    size_t columnNum( string columnName ) const
    {
        return answer.columnNum( columnName );
    }

    /// Returns column name by field number
    string columnName( in size_t colNum ) const
    {
        return answer.columnName( colNum );
    }

    /// Returns column count
    @property size_t length() const{ return answer.columnCount(); }
    
    @property
    debug string toString() const
    {
        return "Columns: "~to!string(length);
    }
}

/// Link to the cell of the answer table
struct Value
{
    package ValueFormat format;
    package OidType oidType;
    package ubyte[] value;

    this(immutable (ubyte)* value, size_t valueSize, ValueFormat f, OidType t)
    {
        this.value = cast(ubyte[]) value[0..valueSize];
        format = f;
        oidType = t;
    }
    
    this( const ubyte[] value, OidType t )
    {
        this.value = cast(ubyte[]) value;
        format = ValueFormat.BINARY;
        oidType = t;
    }

    @property
    bool isSupportedArray() const
    {
        return dpq2.oids.isSupportedArray(oidType);
    }

    @property
    immutable (Array) asArray() immutable
    {
        if(!isSupportedArray)
            throw new AnswerException(ExceptionType.NOT_ARRAY,
                "Format of the column is "~to!string(oidType)~", isn't supported array",
                __FILE__, __LINE__
            );

        return immutable Array(this);
    }
}

private struct ArrayHeader_net // network byte order
{
    ubyte[4] ndims; // number of dimensions of the array
    ubyte[4] dataoffset_ign; // offset for data, removed by libpq. may be it contains isNULL flag!
    ubyte[4] OID; // element type OID
}

private struct Dim_net // network byte order
{
    ubyte[4] dim_size; // number of elements in dimension
    ubyte[4] lbound; // unknown
}

package struct ArrayProperties
{
    OidType OID;
    int nDims; /// Number of dimensions
    int[] dimsSize; /// Dimensions sizes info
    size_t nElems; /// Total elements
    size_t dataOffset;

    this(in Value cell)
    {
        const ArrayHeader_net* h = cast(ArrayHeader_net*) cell.value.ptr;
        nDims = bigEndianToNative!int(h.ndims);
        OID = oid2oidType(bigEndianToNative!Oid(h.OID));

        if(!(nDims > 0))
            throw new AnswerException(ExceptionType.SMALL_DIMENSIONS_NUM,
                "Dimensions number is too small, it must be positive value",
                __FILE__, __LINE__
            );

        dataOffset = ArrayHeader_net.sizeof + Dim_net.sizeof * nDims;

        auto ds = new int[ nDims ];

        // Recognize dimensions of array
        int n_elems = 1;
        for( auto i = 0; i < nDims; ++i )
        {
            Dim_net* d = (cast(Dim_net*) (h + 1)) + i;

            int dim_size = bigEndianToNative!int( d.dim_size );
            int lbound = bigEndianToNative!int(d.lbound);

            if(!(dim_size > 0))
                throw new AnswerException(ExceptionType.FATAL_ERROR,
                    "Dimension size isn't positive ("~to!string(dim_size)~")",
                    __FILE__, __LINE__
                );

            // FIXME: What is lbound in postgresql array reply?
            if(!(lbound == 1))
                throw new AnswerException(ExceptionType.UNDEFINED_FIXME,
                    "Please report if you came across this error! lbound=="~to!string(lbound),
                    __FILE__, __LINE__
                );

            ds[i] = dim_size;
            n_elems *= dim_size;
        }

        nElems = n_elems;
        dimsSize = ds;
    }
}

/// Link to the cell of the answer table
immutable struct Array
{
    ArrayProperties ap;
    alias ap this;

    private ubyte[][] elements; // TODO: it is too slow to place every elements to this array instead of ptrs to them
    private bool[] elementIsNULL;

    this(immutable Value cell)
    {
        if(!(cell.format == ValueFormat.BINARY))
            throw new AnswerException(ExceptionType.NOT_BINARY,
                msg_NOT_BINARY, __FILE__, __LINE__);

        ap = cast(immutable) ArrayProperties(cell);

        // Looping through all elements and fill out index of them
        {
            auto elements = new immutable (ubyte)[][ nElems ];
            auto elementIsNULL = new bool[ nElems ];

            size_t curr_offset = ap.dataOffset;

            for(uint i = 0; i < nElems; ++i )
            {
                ubyte[int.sizeof] size_net; // network byte order
                size_net[] = cell.value[ curr_offset .. curr_offset + size_net.sizeof ];
                uint size = bigEndianToNative!uint( size_net );
                if( size == size.max ) // NULL magic number
                {
                    elementIsNULL[i] = true;
                    size = 0;
                }
                else
                {
                    elementIsNULL[i] = false;
                }
                curr_offset += size_net.sizeof;
                elements[i] = cell.value[curr_offset .. curr_offset + size];
                curr_offset += size;
            }

            this.elements = elements.idup;
            this.elementIsNULL = elementIsNULL.idup;
        }
    }
    
    /// Returns Value struct by index
    immutable (Nullable!Value) opIndex(int n) const
    {
        return getValue(n);
    }
    
    /// Returns Value struct
    /// Useful for multidimensional arrays
    immutable (Nullable!Value) getValue( ... ) immutable
    {
        auto n = coords2Serial( _argptr, _arguments );
        
        Nullable!Value r;
        
        if(!elementIsNULL[n])
            r = Value(elements[n], OID);
        
        return cast(immutable) r;
    }
    
    /// Value NULL checking
    bool isNULL( ... )
    {
        auto n = coords2Serial( _argptr, _arguments );
        return elementIsNULL[n];
    }

    private size_t coords2Serial( va_list _argptr, TypeInfo[] _arguments )
    {
        assert( _arguments.length > 0, "Number of the arguments must be more than 0" );
        
        // Variadic args parsing
        auto args = new int[ _arguments.length ];

        if(!(nDims == args.length))
            throw new AnswerException(
                ExceptionType.OUT_OF_RANGE,
                "Mismatched dimensions number in arguments and server reply",
                __FILE__, __LINE__
            );

        for( uint i; i < args.length; ++i )
        {
            assert( _arguments[i] == typeid(int) );
            args[i] = va_arg!(int)(_argptr);

            if(!(dimsSize[i] > args[i]))
                throw new AnswerException(
                    ExceptionType.OUT_OF_RANGE,
                    "Out of range",
                    __FILE__, __LINE__
                );
        }
        
        // Calculates serial number of the element
        auto inner = args.length - 1; // inner dimension
        auto element_num = args[inner]; // serial number of the element
        uint s = 1; // perpendicular to a vector which size is calculated currently
        for( auto i = inner; i > 0; --i )
        {
            s *= dimsSize[i];
            element_num += s * args[i-1];
        }
        
        assert( element_num <= nElems );
        return element_num;
    }
}

/// Notify
class Notify
{
    private immutable PGnotify* n;

    this(immutable PGnotify* pgn )
    {
        n = pgn;
        cast(void) enforceEx!OutOfMemoryError(n, "Can't write notify");
    }
        
    ~this()
    {
        PQfreemem( cast(void*) n );
    }

    /// Returns notification condition name
    @property string name() { return to!string( n.relname ); }

    /// Returns notification parameter
    @property string extra() { return to!string( n.extra ); }

    /// Returns process ID of notifying server process
    @property size_t pid() { return n.be_pid; }

    nothrow invariant() 
    {
        assert( n != null );
    }
}

immutable msg_NOT_BINARY = "Format of the column is not binary";

/// Exception types
enum ExceptionType
{
    UNDEFINED_FIXME, /// Undefined, please report if you came across this error
    COLUMN_NOT_FOUND, /// Column is not found
    OUT_OF_RANGE,
    NOT_ARRAY, /// Format of the column isn't array
    NOT_BINARY, /// Format of the column isn't binary
    NOT_TEXT, /// Format of the column isn't text string
    NOT_IMPLEMENTED, /// Support of this type isn't implemented (or format isn't matches to specified D type)
    SMALL_DIMENSIONS_NUM,
    SIZE_MISMATCH,
    EMPTY_QUERY,
    FATAL_ERROR
}

/// Exception
class AnswerException : Dpq2Exception
{    
    ExceptionType type; /// Exception type
    
    this(ExceptionType t, string msg, string file, size_t line)
    {
        type = t;
        super(msg, file, line);
    }
}

void _integration_test( string connParam )
{
    auto conn = new Connection;
	conn.connString = connParam;
    conn.connect();

    {
        string sql_query =
        "select now() as time,  'abc'::text as field_name,   123,  456.78\n"~
        "union all\n"~

        "select now(),          'def'::text,                 456,  910.11\n"~
        "union all\n"~

        "select NULL,           'ijk_АБВГД'::text,           789,  12345.115345";

        auto e = conn.exec(sql_query);

        assert( e[1][2].as!PGtext == "456" );
        assert( e[2][1].as!PGtext == "ijk_АБВГД" );
        assert( !e[0].isNULL(0) );
        assert( e[2].isNULL(0) );
        assert( e.columnNum( "field_name" ) == 1 );
        assert( e[1]["field_name"].as!PGtext == "def" );
    }

    QueryParams p;
    p.resultFormat = ValueFormat.BINARY;
    p.sqlCommand = "SELECT "~
        "-32761::smallint, "~
        "-2147483646::integer, "~
        "'first line\nsecond line'::text, "~
        "array[[[1,  2, 3], "~
               "[4,  5, 6]], "~
               
              "[[7,  8, 9], "~
              "[10, 11,12]], "~
              
              "[[13,14,NULL], "~
               "[16,17,18]]]::integer[] as test_array, "~
        "NULL,"~
        "array[11,22,NULL,44]::integer[] as small_array, "~
        "array['1','23',NULL,'789A']::text[] as text_array";

    auto r = conn.exec( p );

    {
        assert( r[0].isNULL(4) );
        assert( !r[0].isNULL(2) );

        assert( r.OID(3) == OidType.Int4Array );
        assert( r.isSupportedArray(3) );
        assert( !r.isSupportedArray(2) );
        auto v = r[0]["test_array"];
        assert( v.isSupportedArray );
        assert( !r[0][2].isSupportedArray );
        auto a = v.asArray;
        assert( a.OID == OidType.Int4 );
        assert( a.getValue(2,1,2).as!PGinteger == 18 );
        assert( a.isNULL(2,0,2) );
        assert( !a.isNULL(2,1,2) );
        assert( r[0]["small_array"].asArray[1].as!PGinteger == 22 );
        assert( r[0]["small_array"].asArray[2].isNull );
        assert( r[0]["text_array"].asArray[2].isNull );
        assert( r.columnName(3) == "test_array" );
        assert( r[0].columnName(3) == "test_array" );

        {
            bool isNullFlag = false;
            try
                cast(void) r[0][4].as!PGsmallint;
            catch(AssertError)
                isNullFlag = true;
            finally
                assert(isNullFlag);
        }
    }

    // Notifies test
    conn.exec( "listen test_notify; notify test_notify" );
    assert( conn.getNextNotify.name == "test_notify" );
    
    // Async query test 1
    conn.sendQuery( "select 123; select 456; select 789" );
    while( conn.getAnswer() !is null ){}
    assert( conn.getAnswer() is null ); // removes null answer at the end

    // Async query test 2
    conn.sendQuery( p );
    while( conn.getAnswer() !is null ){}
    assert( conn.getAnswer() is null ); // removes null answer at the end

    {
        // Range test
        auto rowsRange = Rangify!(immutable Answer)(r);
        size_t count = 0;

        foreach(row; rowsRange)
            foreach(elem; Rangify!Row(row))
                count++;

        assert(count == 7);
    }

    destroy(r);

    {
        bool exceptionFlag = false;

        try conn.exec("WRONG SQL QUERY");
        catch(AnswerException e)
        {
            exceptionFlag = true;
            assert(e.msg.length > 20); // error message check
        }
        finally
            assert(exceptionFlag);
    }
}
