requires 'perl', '5.016';
requires 'Digest::SHA';
requires 'JSON::PP';
requires 'Scalar::Util';

on test => sub {
  requires 'Test2::V0';
  requires 'Test::Harness';
};

on develop => sub {
  requires 'Devel::Cover';
};
