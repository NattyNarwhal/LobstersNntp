%%% Copyright 2009 Andrew Thompson <andrew@hijacked.us>. All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%%   1. Redistributions of source code must retain the above copyright notice,
%%%      this list of conditions and the following disclaimer.
%%%   2. Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR
%%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
%%% EVENT SHALL THE FREEBSD PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
%%% INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

% This is some private functions from gen_smtp we use directly
-module(lobsters_nntp_mime).
-export([wrap_to_76/1, encode_quoted_printable/1]).

wrap_to_76(String) ->
	[wrap_to_76(String, [])].
wrap_to_76(<<>>, Acc) ->
	list_to_binary(lists:reverse(Acc));
wrap_to_76(<<Head:76/binary, Tail/binary>>, Acc) ->
	wrap_to_76(Tail, [<<"\r\n">>, Head | Acc]);
wrap_to_76(Head, Acc) ->
	list_to_binary(lists:reverse([<<"\r\n">>, Head | Acc])).

encode_quoted_printable(Body) ->
	[encode_quoted_printable(Body, [], 0)].

encode_quoted_printable(Body, Acc, L) when L >= 75 ->
	LastLine = case string:str(Acc, "\n") of
		0 ->
			Acc;
		Index ->
			string:substr(Acc, 1, Index-1)
	end,
	%Len = length(LastLine),
	case string:str(LastLine, " ") of
		0 when L =:= 75 ->
			% uh-oh, no convienient whitespace, just cram a soft newline in
			encode_quoted_printable(Body, [$\n, $\r, $= | Acc], 0);
		1 when L =:= 75 ->
			% whitespace is the last character we wrote
			encode_quoted_printable(Body, [$\n, $\r, $= | Acc], 0);
		SIndex when (L - 75) < SIndex ->
			% okay, we can safely stick some whitespace in
			NewAcc = insert_soft_newline(Acc, SIndex - 1),
			encode_quoted_printable(Body, NewAcc, 0);
		_ ->
			% worst case, we're over 75 characters on the line
			% and there's no obvious break points, just stick one
			% in at position 75 and call it good. However, we have
			% to be very careful not to stick the soft newline in
			% the middle of an existing quoted-printable escape.

			% TODO - fix this to be less stupid
			I = 3, % assume we're at most 3 over our cutoff
			NewAcc = insert_soft_newline(Acc, I),
			encode_quoted_printable(Body, NewAcc, 0)
	end;
encode_quoted_printable(<<>>, Acc, _L) ->
	list_to_binary(lists:reverse(Acc));
encode_quoted_printable(<<$=, T/binary>> , Acc, L) ->
	encode_quoted_printable(T, [$D, $3, $= | Acc], L+3);
encode_quoted_printable(<<$\r, $\n, T/binary>> , Acc, _L) ->
	encode_quoted_printable(T, [$\n, $\r | Acc], 0);
encode_quoted_printable(<<H, T/binary>>, Acc, L) when H >= $!, H =< $< ->
	encode_quoted_printable(T, [H | Acc], L+1);
encode_quoted_printable(<<H, T/binary>>, Acc, L) when H >= $>, H =< $~ ->
	encode_quoted_printable(T, [H | Acc], L+1);
encode_quoted_printable(<<H, $\r, $\n, T/binary>>, Acc, _L) when H == $\s; H == $\t ->
	[A, B] = lists:flatten(io_lib:format("~2.16.0B", [H])),
	encode_quoted_printable(T, [$\n, $\r, B, A, $= | Acc], 0);
encode_quoted_printable(<<H, T/binary>>, Acc, L) when H == $\s; H == $\t ->
	encode_quoted_printable(T, [H | Acc], L+1);
encode_quoted_printable(<<H, T/binary>>, Acc, L) ->
	[A, B] = lists:flatten(io_lib:format("~2.16.0B", [H])),
	encode_quoted_printable(T, [B, A, $= | Acc], L+3).

insert_soft_newline([H | T], AfterPos) when AfterPos > 0 ->
	[H | insert_soft_newline(T, AfterPos - 1)];
insert_soft_newline(Str, 0) ->
	[$\n, $\r, $= | Str].
