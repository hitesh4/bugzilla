# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Markdown;

use 5.14.0;
use strict;
use warnings;

use Bugzilla::Constants;
use Bugzilla::Template;

use Digest::MD5 qw(md5_hex);

use parent qw(Text::MultiMarkdown);

# use private code points
use constant FENCED_BLOCK => "\N{U+F111}";
use constant INDENTED_FENCED_BLOCK => "\N{U+F222}";

# Regex to match balanced [brackets]. See Friedl's
# "Mastering Regular Expressions", 2nd Ed., pp. 328-331.
our ($g_nested_brackets, $g_nested_parens);
$g_nested_brackets = qr{
    (?>                                 # Atomic matching
       [^\[\]]+                         # Anything other than brackets
     |
       \[
         (??{ $g_nested_brackets })     # Recursive set of nested brackets
       \]
    )*
}x;
# Doesn't allow for whitespace, because we're using it to match URLs:
$g_nested_parens = qr{
    (?>                                 # Atomic matching
       [^()\s]+                            # Anything other than parens or whitespace
     |
       \(
         (??{ $g_nested_parens })        # Recursive set of nested brackets
       \)
    )*
}x;

our %g_escape_table;

foreach my $char (split //, '\\`*_{}[]()>#+-.!~') {
    $g_escape_table{$char} = md5_hex($char);
}
$g_escape_table{'&lt;'} = md5_hex('&lt;');

sub new {
    my $invocant = shift;
    my $class = ref $invocant || $invocant;
    my $obj = $class->SUPER::new(tab_width => MARKDOWN_TAB_WIDTH,
                              # Bugzilla uses HTML not XHTML
                              empty_element_suffix => '>');
    $obj->{tab_width} = MARKDOWN_TAB_WIDTH;
    $obj->{empty_element_suffix} = '>';
    return $obj;
}

sub markdown {
    my ($self, $text, $bug, $comment) = @_;
    my $user = Bugzilla->user;

    if ($user->settings->{use_markdown}->{is_enabled}
        && $user->setting('use_markdown') eq 'on')
    {
        $text = $self->_removeFencedCodeBlocks($text);
        $text = Bugzilla::Template::quoteUrls($text, $bug, $comment, $user, 1);
        return $self->SUPER::markdown($text);
    }

    return Bugzilla::Template::quoteUrls($text, $bug, $comment, $user);
}

sub _code_blocks {
    my ($self) = @_;
    $self->{code_blocks} = $self->{params}->{code_blocks} ||= [];
    return $self->{code_blocks};
}

sub _indented_code_blocks {
    my ($self) = @_;
    $self->{indented_code_blocks} = $self->{params}->{indented_code_blocks} ||= [];
    return $self->{indented_code_blocks};
}

sub _RunSpanGamut {
    # These are all the transformations that occur *within* block-level
    # tags like paragraphs, headers, and list items.

    my ($self, $text) = @_;

    $text = $self->_DoCodeSpans($text);
    $text = $self->_EscapeSpecialCharsWithinTagAttributes($text);
    $text = $self->_EscapeSpecialChars($text);

    $text = $self->_DoAnchors($text);

    # Strikethroughs is Bugzilla's extension
    $text = $self->_DoStrikethroughs($text);

    $text = $self->_DoAutoLinks($text);
    $text = $self->_EncodeAmpsAndAngles($text);
    $text = $self->_DoItalicsAndBold($text);

    $text =~ s/\n/<br$self->{empty_element_suffix}\n/g;

    return $text;
}

# We first replace all fenced code blocks with just their
# surrounding backticks and an empty body to know where
# they are exactly for later processing. The bodies of
# blocks will be in an array. This measure is taken to not
# interpret fenced code blocks contents as possible markdown
# structures. The contents of the body will be processed after
# processing markdown structures.
sub _removeFencedCodeBlocks {
    my ($self, $text) = @_;
    $text =~ s{
        ^ `{3,} [\s\t]* \n
        (                # $1 = the entire code block
          (?: .* \n+)+?
        )
        `{3,} [\s\t]* $
        }{
            push @{$self->_code_blocks}, $1;
            "${\FENCED_BLOCK}\n";
        }egmx;

    $text =~ s{
        (?:\n\n|\A)
        (                # $1 = the code block -- one or more lines, starting with a space/tab
          (?:
            (?:[ ]{$self->{tab_width}} | \t)   # Lines must start with a tab or a tab-width of spaces
            .*\n+
          )+
        )
        ((?=^[ ]{0,$self->{tab_width}}\S)|\Z)    # Lookahead for non-space at line-start, or end of doc
        }{
            push @{$self->_indented_code_blocks}, $1;
            "\n${\INDENTED_FENCED_BLOCK}\n";
        }egmx;
    return $text;
}

# Override to check for HTML-escaped <>" chars.
sub _StripLinkDefinitions {
    my ($self, $text) = @_;

    #
    # Strips link definitions from text, stores the URLs and titles in
    # hash references.
    #
    my $less_than_tab = $self->{tab_width} - 1;

    # Link defs are in the form: ^[id]: url "optional title"
    while ($text =~ s{
            ^[ ]{0,$less_than_tab}\[(.+)\]: # id = \$1
              [ \t]*
              \n?               # maybe *one* newline
              [ \t]*
            (?:&lt;)?<a\s+href="(.+?)">\2</a>(?:&gt;)?          # url = \$2
              [ \t]*
              \n?               # maybe one newline
              [ \t]*
            (?:
                (?<=\s)         # lookbehind for whitespace
                (?:&quot;|\()
                (.+?)           # title = \$3
                (?:&quot;|\))
                [ \t]*
            )?  # title is optional
            (?:\n+|\Z)
        }{}omx) {
        $self->{_urls}{lc $1} = $self->_EncodeAmpsAndAngles( $2 );    # Link IDs are case-insensitive
        if ($3) {
            $self->{_titles}{lc $1} = $3;
            $self->{_titles}{lc $1} =~ s/"/&quot;/g;
        }

    }

    return $text;
}

# We need to look for HTML-escaped '<' and '>' (i.e. &lt; and &gt;).
# We also remove Email linkification from the original implementation
# as it is already done in Bugzilla's quoteUrls().
sub _DoAutoLinks {
    my ($self, $text) = @_;

    $text =~ s{(?:<|&lt;)((?:https?|ftp):[^'">\s]+?)(?:>|&gt;)}{<a href="$1">$1</a>}gi;
    return $text;
}

# The main reasons for overriding this method are
# resolving URL conflicts with Bugzilla's quoteUrls()
# and also changing '"' to '&quot;' in regular expressions wherever needed.
sub _DoAnchors {
#
# Turn Markdown link shortcuts into <a> tags.
#
    my ($self, $text) = @_;

    # We revert linkifications of non-email links and only
    # those links whose URL and title are the same because
    # this way we can be sure that link is generated by quoteUrls()
    $text =~ s@<a \s+ href="(?! mailto ) (.+?)">\1</a>@$1@xmg;

    #
    # First, handle reference-style links: [link text] [id]
    #
    $text =~ s{
        (                   # wrap whole match in $1
          \[
            ($g_nested_brackets)    # link text = $2
          \]

          [ ]?              # one optional space
          (?:\n[ ]*)?       # one optional newline followed by spaces

          \[
            (.*?)       # id = $3
          \]
        )
    }{
        my $whole_match = $1;
        my $link_text   = $2;
        my $link_id     = lc $3;

        if ($link_id eq "") {
            $link_id = lc $link_text;   # for shortcut links like [this][].
        }

        $link_id =~ s{[ ]*\n}{ }g; # turn embedded newlines into spaces

        $self->_GenerateAnchor($whole_match, $link_text, $link_id);
    }xsge;

    #
    # Next, inline-style links: [link text](url "optional title")
    #
    $text =~ s{
        (               # wrap whole match in $1
          \[
            ($g_nested_brackets)    # link text = $2
          \]
          \(            # literal paren
            [ \t]*
            ($g_nested_parens)   # href = $3
            [ \t]*
            (           # $4
              (&quot;|')    # quote char = $5
              (.*?)     # Title = $6
              \5        # matching quote
              [ \t]*    # ignore any spaces/tabs between closing quote and )
            )?          # title is optional
          \)
        )
    }{
        my $result;
        my $whole_match = $1;
        my $link_text   = $2;
        my $url         = $3;
        my $title       = $6;

        # Remove Bugzilla quoteUrls() linkification
        if ($url =~ /^a href="/ && $url =~ m|</a$|) {
            $url =~ s/^[^>]+>//;
            $url =~ s@</a$@@;
        }

        my $safe_url_regexp = Bugzilla::Template::SAFE_URL_REGEXP();
        $url = "http://$url" unless $url =~ /^$safe_url_regexp$/;

        $self->_GenerateAnchor($whole_match, $link_text, undef, $url, $title);
    }xsge;

    #
    # Handle reference-style shortcuts: [link text]
    # These must come last in case you've also got [link test][1]
    # or [link test](/foo)
    #
    $text =~ s{
        (                    # wrap whole match in $1
          \[
            ([^\[\]]+)        # link text = $2; can't contain '[' or ']'
          \]
        )
    }{
        my $result;
        my $whole_match = $1;
        my $link_text   = $2;
        (my $link_id = lc $2) =~ s{[ ]*\n}{ }g; # lower-case and turn embedded newlines into spaces

        $self->_GenerateAnchor($whole_match, $link_text, $link_id);
    }xsge;

    # Last, handle "naked" references
    # Caveat, does not handle ;http://amazon.com
    my $safe_url_regexp = Bugzilla::Template::SAFE_URL_REGEXP();
    $text =~ s{
        (
          (^|(?<![;^"'<>]))  # negative lookbehind, including ';' in '&lt;'
          (                  # wrap url in $3
             (?:https?|ftp):[^'">\s]+\w
          )
        )
    }{
        my $whole_match = $3;
        my $url = $whole_match;
        $self->_GenerateAnchor($whole_match, $url, undef, $url, undef);
    }xsge;

    return $text;
}

# The purpose of overriding this function is to add support
# for a Github Flavored Markdown (GFM) feature called 'Multiple
# underscores in words'. The standard markdown specification
# specifies the underscore for making the text emphasized/bold.
# However, some variable names in programming languages contain underscores
# and we do not want a part of those variables to look emphasized/bold.
# Instead, we render them as the way they originally are.
sub _DoItalicsAndBold {
    my ($self, $text) = @_;

    # Handle at beginning of lines:
    $text =~ s{ (^__ (?=\S) (.+?[*_]*) (?<=\S) __ (?!\S)) }
              {
                  my $result = _has_multiple_underscores($2) ? $1 : "<strong>$2</strong>";
                  $result;
              }gsxe;

    $text =~ s{ ^\*\* (?=\S) (.+?[*_]*) (?<=\S) \*\* }{<strong>$1</strong>}gsx;

    $text =~ s{ (^_ (?=\S) (.+?) (?<=\S) _ (?!\S)) }
              {
                  my $result = _has_multiple_underscores($2) ? $1 : "<em>$2</em>";
                  $result;
              }gsxe;

    $text =~ s{ ^\* (?=\S) (.+?) (?<=\S) \* }{<em>$1</em>}gsx;

    # <strong> must go first:
    $text =~ s{ ( (?<=\W) __ (?=\S) (.+?[*_]*) (?<=\S) __ (?!\S) ) }
              {
                  my $result = _has_multiple_underscores($2) ? $1 : "<strong>$2</strong>";
                  $result;
              }gsxe;


    $text =~ s{ (?<=\W) \*\* (?=\S) (.+?[*_]*) (?<=\S) \*\* }{<strong>$1</strong>}gsx;

    $text =~ s{ ( (?<=\W) _ (?=\S) (.+?) (?<=\S) _ (?!\S) ) }
              {
                  my $result = _has_multiple_underscores($2) ? $1 : "<em>$2</em>";
                  $result;
              }gsxe;

    $text =~ s{ (?<=\W) \* (?=\S) (.+?) (?<=\S) \* }{<em>$1</em>}gsx;

    # And now, a second pass to catch nested strong and emphasis special cases
    $text =~ s{ ( (?<=\W) __ (?=\S) (.+?[*_]*) (?<=\S) __ (\S*) ) }
              {
                  my $result = _has_multiple_underscores($3) ? $1 : "<strong>$2</strong>$3";
                  $result;
              }gsxe;

    $text =~ s{ (?<=\W) \*\* (?=\S) (.+?[*_]*) (?<=\S) \*\* }{<strong>$1</strong>}gsx;
    $text =~ s{ ( (?<=\W) _ (?=\S) (.+?) (?<=\S) _ (\S*) ) }
              {
                  my $result = _has_multiple_underscores($3) ? $1 : "<em>$2</em>$3";
                  $result;
              }gsxe;

    $text =~ s{ (?<=\W) \* (?=\S) (.+?) (?<=\S) \* }{<em>$1</em>}gsx;

    return $text;
}

sub _DoStrikethroughs {
    my ($self, $text) = @_;

    $text =~ s{ ^ ~~ (?=\S) ([^~]+?) (?<=\S) ~~ (?!~) }{<del>$1</del>}gsx;
    $text =~ s{ (?<=_|[^~\w]) ~~ (?=\S) ([^~]+?) (?<=\S) ~~ (?!~) }{<del>$1</del>}gsx;

    return $text;
}

# The original _DoCodeSpans() uses the 's' modifier in its regex
# which prevents _DoCodeBlocks() to match GFM fenced code blocks.
# We copy the code from the original implementation and remove the
# 's' modifier from it.
sub _DoCodeSpans {
    my ($self, $text) = @_;

    $text =~ s@
            (?<!\\)     # Character before opening ` can't be a backslash
            (`+)        # $1 = Opening run of `
            (.+?)       # $2 = The code block
            (?<!`)
            \1          # Matching closer
            (?!`)
        @
             my $c = "$2";
             $c =~ s/^[ \t]*//g; # leading whitespace
             $c =~ s/[ \t]*$//g; # trailing whitespace
             $c = $self->_EncodeCode($c);
            "<code>$c</code>";
        @egx;

    return $text;
}

# Override to add GFM Fenced Code Blocks
sub _DoCodeBlocks {
    my ($self, $text) = @_;

    $text =~ s{
        ^ (${\FENCED_BLOCK}|${\INDENTED_FENCED_BLOCK})
        }{
            my $aref = ($1 eq FENCED_BLOCK) ? $self->_code_blocks : $self->_indented_code_blocks;
            my $codeblock = shift @$aref;
            my $result;

            $codeblock = $self->_EncodeCode($codeblock);
            $codeblock = $self->_Detab($codeblock);
            $codeblock =~ s/\n\z//; # remove the trailing newline

            $result = "\n\n<pre><code>" . $codeblock . "</code></pre>\n\n";
            $result;
        }egmx;

    return $text;
}

sub _DoBlockQuotes {
    my ($self, $text) = @_;

    $text =~ s{
          (                             # Wrap whole match in $1
            (?:
              ^[ \t]*&gt;[ \t]?         # '>' at the start of a line
                .+\n                    # rest of the first line
              (?:.+\n)*                 # subsequent consecutive lines
              \n*                       # blanks
            )+
          )
        }{
            my $bq = $1;
            $bq =~ s/^[ \t]*&gt;[ \t]?//gm; # trim one level of quoting
            $bq =~ s/^[ \t]+$//mg;          # trim whitespace-only lines
            $bq = $self->_RunBlockGamut($bq, {wrap_in_p_tags => 1});      # recurse
            $bq =~ s/^/  /mg;
            # These leading spaces screw with <pre> content, so we need to fix that:
            $bq =~ s{(\s*<pre>.+?</pre>)}{
                        my $pre = $1;
                        $pre =~ s/^  //mg;
                        $pre;
                    }egs;
            "<blockquote class=\"markdown\">\n$bq\n</blockquote>\n\n";
        }egmx;

    return $text;
}

sub _DoLists {
    my ($self, $text) = @_;

    $text = $self->SUPER::_DoLists($text);

    # strip trailing newlines created by DoLists
    $text =~ s/\n</</g;

    return $text;
}

sub _EncodeCode {
    my ($self, $text) = @_;

    # We need to unescape the escaped HTML characters in code blocks.
    # These are the reverse of the escapings done in Bugzilla::Util::html_quote()
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&quot;/"/g;
    $text =~ s/&#64;/@/g;
    # '&amp;' substitution must be the last one, otherwise a literal like '&gt;'
    # will turn to '>' because '&' is already changed to '&amp;' in Bugzilla::Util::html_quote().
    # In other words, html_quote() will change '&gt;' to '&amp;gt;' and then we will
    # change '&amp;gt' -> '&gt;' -> '>' if we write this substitution as the first one.
    $text =~ s/&amp;/&/g;
    $text =~ s{<a \s+ href="(?:mailto:)? (.+?)"> \1 </a>}{$1}xmgi;
    $text = $self->SUPER::_EncodeCode($text);
    $text =~ s/~/$g_escape_table{'~'}/go;
    # Encode '&lt;' to prevent URLs from getting linkified in code spans
    $text =~ s/&lt;/$g_escape_table{'&lt;'}/go;

    return $text;
}

sub _EncodeBackslashEscapes {
    my ($self, $text) = @_;

    $text = $self->SUPER::_EncodeBackslashEscapes($text);
    $text =~ s/\\~/$g_escape_table{'~'}/go;

    return $text;
}

sub _UnescapeSpecialChars {
    my ($self, $text) = @_;

    $text = $self->SUPER::_UnescapeSpecialChars($text);
    $text =~ s/$g_escape_table{'~'}/~/go;
    $text =~ s/$g_escape_table{'&lt;'}/&lt;/go;

    return $text;
}

# Check if the passed string is of the form multiple_underscores_in_a_word.
# To check that, we first need to make sure that the string does not contain
# any white-space. Then, if the string is composed of non-space chunks which
# are bound together with underscores, the string has the desired form.
sub _has_multiple_underscores {
    my $string = shift;
    return 0 unless $string;
    return 0 if $string =~ /\s/;
    return 1 if $string =~ /_/;
    return 0;
}

1;

__END__

=head1 NAME

Bugzilla::Markdown - Generates HTML output from structured plain-text input.

=head1 SYNOPSIS

 use Bugzilla::Markdown;

 my $markdown = Bugzilla::Markdown->new();
 print $markdown->markdown($text);

=head1 DESCRIPTION

Bugzilla::Markdown implements a Markdown engine that produces
an HTML-based output from a given plain-text input.

The majority of the implementation is done by C<Text::MultiMarkdown>
CPAN module. It also applies the linkifications done in L<Bugzilla::Template>
to the input resulting in an output which is a combination of both Markdown
structures and those defined by Bugzilla itself.

=head2 Accessors

=over

=item C<markdown>

C<string> Produces an HTML-based output string based on the structures
and format defined in the given plain-text input.

=over

=item B<Params>

=over

=item C<text>

C<string> A plain-text string which includes Markdown structures.

=back

=back

=back
