#!/usr/bin/env perl

########################################################################
# Copyright (c) 2013, NVIDIA CORPORATION.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and/or associated documentation files (the
# "Materials"), to deal in the Materials without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Materials, and to
# permit persons to whom the Materials are furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be included
# unaltered in all copies or substantial portions of the Materials.
# Any additions, deletions, or changes to the original source files
# must be clearly indicated in accompanying documentation.
#
# If only executable code is distributed, then the accompanying
# documentation must state that "this software is based in part on the
# work of the Khronos Group."
#
# THE MATERIALS ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# MATERIALS OR THE USE OR OTHER DEALINGS IN THE MATERIALS.
########################################################################

########################################################################
#
# gen_stubs.pl
#
# This parses glx_funcs.spec and generates noop functions for libGLX.so, as
# well as wrapper functions for libGL.so.
#
########################################################################

use strict;

die "syntax: gen_stubs.pl <mode> <specfile>" if @ARGV < 2;

my $mode = @ARGV[0];
my $specfile = @ARGV[1];

my $q = "(?:\\S+|\"[^\"]*\"|\'[^\']*\')"; # Possibly quoted string

sub add_function
{
    my $function = shift;
    my $functions = shift;

    if ($function->{'name'}) {
        push @$functions, { %$function };
    }

    undef %$function;
}

sub unquote
{
    my $tmp = shift;
    if (!$tmp) {
        return undef;
    }
    $tmp =~ s/^(?|([^'"]\S+)|"([^"]*)"|'([^']*)')$/\1/;
    $tmp;
}

sub get_param
{
    my $params = shift;
    my $typepat = shift;
    my $valpat = shift;
    foreach my $param (@$params) {
        if (@$param[0] =~ /$typepat/ and
            @$param[1] =~ /$valpat/) {
            return $param;
        }
    }
    return undef;
}

sub parse_spec
{
    my $linenum = 0;
    my @functions = ();
    my %function = ();
    open (SPEC, $specfile) or die "can't open spec file!\n";

    while (<SPEC>)
    {
        $linenum++;
        s/^\s+//;           # Trim leading whitespace
        s/^\s+$//;          # Trim trailing whitespace
        next if m/^\s*$/;   # Ignore blank lines
        next if m/^\s*#/;   # Ignore comment lines

        if (/^function\s+(.+)$/) {
            add_function(\%function, \@functions);
            $function{'name'} = unquote($1);
            @{$function{'params'}} = ();
            $function{'prefix'} = "glX";
        } elsif (/^returns\s+($q)\s+($q)$/) {
            $function{'returns'} = unquote($1);
            $function{'default_retval'} = unquote($2);
        } elsif (/^param\s+($q)\s+($q)$/) {
            push @{$function{'params'}}, [unquote($1), unquote($2)];
        } elsif (/^glx14ep$/) {
            $function{'glx14ep'} = 1;
        } else {
            die "Unknown keyword on nonempty line";
        }
    }

    add_function(\%function, \@functions);
    @functions;
}

sub print_disclaimer
{
    print "/*\n";
    print " * THIS FILE IS AUTOMATICALLY GENERATED BY gen_noop.pl\n";
    print " * DO NOT EDIT!!\n";
    print " */\n";
}

sub get_param_proto_list
{
    my $function = shift;
    my @params = map (@$_[0] . ' ' . @$_[1],
                      @{$function->{"params"}});
    if (!(scalar @params)) {
        "void";
    } else {
        join (", ", @params);
    }
}

sub get_param_pass_list
{
    my $function = shift;
    my @params = map (@$_[1], @{$function->{"params"}});
    join (", ", @params);
}

sub name_len {
    my $function = shift;
    length($function->{"name"});
}

sub print_noop_funcs {
    my $functions = shift;
    my $noop_defs = "";
    my $fill_struct = "";

    # Compute maximum name length for padding
    my $max_len = name_len(@$functions[0]);

    foreach my $function (@$functions) {
        if (length(name_len($function) > $max_len)) {
            $max_len = name_len($function);
        }
    }

    foreach my $function (@$functions) {
        my $name = $function->{"name"};
        my $struct_field = lcfirst($name);
        my $param_proto_list = get_param_proto_list($function);
        my $param_pass_list = get_param_pass_list($function);
        my $rettype = $function->{"returns"};
        my $retval = $function->{"default_retval"};
        $noop_defs .= "GLXNOOP $rettype __glX${name}Noop($param_proto_list)\n";
        $noop_defs .= "{\n";
        if ($rettype ne "void") {
        $noop_defs .= "    return $retval;\n";
        } else {
        $noop_defs .= "    return;\n";
        }
        $noop_defs .= "}\n";
        $noop_defs .= "\n";

        if ($function->{"glx14ep"}) {
            $fill_struct .= sprintf("%8s %*s = %s,\n",
                                    " ",
                                    -$max_len, ".$struct_field",
                                    "__glX${name}Noop");
        }
    }

    print_disclaimer();
    print "#include <X11/Xlib.h>\n";
    print "#include <GL/glx.h>\n";
    print "\n";
    print "#include \"libglxabipriv.h\"\n";
    print "#include \"libglxnoop.h\"\n";
    print "\n";
    print "#define GLXNOOP static __attribute__((unused))\n";
    print "\n";
    print $noop_defs;
    print "\n";
    print "const __GLXdispatchTableStatic __glXDispatchNoop = {\n";
    print "    .glx14ep = {\n";
    print $fill_struct;
    print "    }\n";
    print "};\n";
    print "\n";
    print "const __GLXdispatchTableStatic *__glXDispatchNoopPtr = &__glXDispatchNoop;\n";
}

sub print_gl_wrapper {
    my $functions = shift;
    my $fnptrs = "";
    my $wrappers = "";
    my $init_assign = "";
    foreach my $function (@$functions) {
        my $name = $function->{"name"};
        my $param_proto_list = get_param_proto_list($function);
        my $param_pass_list = get_param_pass_list($function);
        my $rettype = $function->{"returns"};
        my $retval = $function->{"default_retval"};
        my $fnptrtype = "fn_${name}_ptr";
        my $fnptrname = "__glXReal$name";

        $fnptrs .= "typedef $rettype (*$fnptrtype)($param_proto_list);\n";
        $fnptrs .= "static $fnptrtype $fnptrname;\n";
        $fnptrs .= "\n";

        $wrappers .= "PUBLIC $rettype glX${name}($param_proto_list)\n";
        $wrappers .= "{\n";
        if ($rettype ne "void") {
        $wrappers .= "    $rettype ret = $retval;\n";
        }
        $wrappers .= "    if ($fnptrname) {\n";
        if ($rettype ne "void") {
        $wrappers .= "        ret = (*$fnptrname)($param_pass_list);\n";
        } else {
        $wrappers .= "        (*$fnptrname)($param_pass_list);\n";
        }
        $wrappers .= "    }\n";
        if ($rettype ne "void") {
        $wrappers .= "    return ret;\n";
        }
        $wrappers .= "}\n";
        $wrappers .= "\n";

        $init_assign .= "    $fnptrname = ($fnptrtype)pGetProcAddress((const GLubyte *)\"glX$name\");\n";
    }

    print_disclaimer();
    print "#include <X11/Xlib.h>\n";
    print "#include <GL/glx.h>\n";
    print "#include \"compiler.h\"\n";
    print "#include \"libgl.h\"\n";
    print "\n";
    print $fnptrs;
    print "\n";
    print $wrappers;
    print "\n";
    print "void __glXWrapperInit(__GLXGetCachedProcAddressPtr pGetProcAddress)\n";
    print "{\n";
    print $init_assign;
    print "}\n";
}

my @functions = parse_spec();

if ($mode eq "noop") {
    print_noop_funcs(\@functions);
} elsif ($mode eq "glwrap") {
    print_gl_wrapper(\@functions);
} else {
    die "unknown mode $mode";
}
