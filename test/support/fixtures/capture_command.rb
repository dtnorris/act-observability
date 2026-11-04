# frozen_string_literal: true

# Finite non-Git child: fixed binary streams and a genuine failing exit status.
STDOUT.binmode.write("out\x00\xff".b)
STDERR.binmode.write("err\x80".b)
exit 7
