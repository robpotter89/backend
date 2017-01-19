from mediawords.util.perl import *


def test_decode_object_from_bytes_if_needed():
    assert decode_object_from_bytes_if_needed(b'foo') == 'foo'
    assert decode_object_from_bytes_if_needed('foo') == 'foo'
    # noinspection PyTypeChecker
    assert decode_object_from_bytes_if_needed(42) == 42
    assert decode_object_from_bytes_if_needed(None) is None

    input_obj = {
        b'a': b'b',
        b'c': [
            b'd',
            b'e',
            b'f',
        ],
        b'g': {
            b'h': {
                b'i': 42,
                'j': None,
            }
        }
    }
    expected = {
        'a': 'b',
        'c': [
            'd',
            'e',
            'f',
        ],
        'g': {
            'h': {
                'i': 42,
                'j': None,
            }
        }
    }
    got = decode_object_from_bytes_if_needed(input_obj)
    assert expected == got


# noinspection SqlResolve,SpellCheckingInspection
def test_convert_dbd_pg_arguments_to_psycopg2_format():
    # Native psycopg2 query with tuple
    input_parameters = ("SELECT * FROM foo WHERE name = %s AND surname = %s", ('Kim', 'Kardashian',))
    expected_parameters = input_parameters
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    # Native psycopg2 query with dictionary
    input_parameters = ("SELECT * FROM foo WHERE name = %(name)s AND surname = %(name)s", {
        'name': 'Kim',
        'surname': 'Kardashian'
    })
    expected_parameters = input_parameters
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    # DBD::Pg's query with no parameters
    input_parameters = ("SELECT * FROM foo WHERE meaning_of_life = 42",)
    expected_parameters = input_parameters
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    # DBD::Pg's query with '%' string literal
    input_parameters = ("SELECT * FROM foo WHERE surname LIKE 'Kardash%'",)
    expected_parameters = input_parameters
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    # DBD::Pg's query with a question mark-style ("?") parameters
    input_parameters = ("""
        SELECT *
        FROM foo
        WHERE name = ?
          AND meaning_of_life = ?
          AND feeling_lucky_today = ?
        """.strip(), 'Kim', 42, True)
    expected_parameters = ("""
        SELECT *
        FROM foo
        WHERE name = %s
          AND meaning_of_life = %s
          AND feeling_lucky_today = %s
        """.strip(), ('Kim', 42, True))
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    input_parameters = ("""INSERT INTO foo (a, b, c) VALUES (?, ?, ?)""".strip(), 'Kim', 42, True)
    expected_parameters = ("""INSERT INTO foo (a, b, c) VALUES (%s, %s, %s)""".strip(), ('Kim', 42, True))
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    # Question mark before "::"
    input_parameters = ("""INSERT INTO foo (a) VALUES (?::datetime)""".strip(), '2017-01-18')
    expected_parameters = ("""INSERT INTO foo (a) VALUES (%s::datetime)""".strip(), ('2017-01-18',))
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    # DBIx::Simple's query with a multiple question mark-style ("WHERE id IN (??)") parameters
    input_sql = "SELECT * FROM foo "
    input_sql += "WHERE name IN (??)"
    input_parameters = (input_sql, 'Kourtney', 'Kim', 'Kylie')
    expected_parameters = ('SELECT * FROM foo WHERE name IN %s', (('Kourtney', 'Kim', 'Kylie'),))
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    # DBD::Pg's query with a dollar sign-style ("$1", "$2", ...) parameters
    input_parameters = ("""
        SELECT *
        FROM foo
        WHERE name = $1
          AND meaning_of_life = $2
          AND name = $1""".strip(), 'Kim', 42)
    expected_parameters = ("""
        SELECT *
        FROM foo
        WHERE name = %(param_1)s
          AND meaning_of_life = %(param_2)s
          AND name = %(param_1)s""".strip(), {'param_1': 'Kim', 'param_2': 42}
                           )
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters

    input_parameters = ("""INSERT INTO foo (a, b, c) VALUES ($2, $1, $3)""".strip(), 'Kim', 42, True)
    expected_parameters = (
        """INSERT INTO foo (a, b, c) VALUES (%(param_2)s, %(param_1)s, %(param_3)s)""".strip(),
        {'param_1': 'Kim', 'param_2': 42, 'param_3': True}
    )
    actual_parameters = convert_dbd_pg_arguments_to_psycopg2_format(*input_parameters)
    assert expected_parameters == actual_parameters


def test_psycopg2_exception_due_to_boolean_passed_as_int_column():
    assert psycopg2_exception_due_to_boolean_passed_as_int_column('foo') is None
    assert psycopg2_exception_due_to_boolean_passed_as_int_column(
        'column "married_to_kanye" is of type boolean but expression is of type integer'
    ) == 'married_to_kanye'
