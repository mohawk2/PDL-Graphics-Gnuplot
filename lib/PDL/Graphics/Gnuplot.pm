package PDL::Graphics::Gnuplot;

use strict;
use warnings;
use PDL;
use IO::Handle;
use List::Util qw(first);
use Storable qw(dclone);

use feature qw(say);
our $VERSION = 0.01;

$PDL::use_commas = 1;

use base 'Exporter';
our @EXPORT_OK = qw(plot);

# if I call plot() as a global function I create a new PDL::Graphics::Gnuplot
# object. I would like the gnuplot process to persist to keep the plot
# interactive at least while the perl program is running. This global variable
# keeps the new object referenced so that it does not get deleted. Once can
# create their own PDL::Graphics::Gnuplot objects, but there's one free global
# one available
my $globalPlot;

# I make a list of all the options. I can use this list to determine if an
# options hash I encounter is for the plot, or for a curve
my @allPlotOptions = qw(3d dump extracmds hardcopy nogrid square square_xy title
                        globalwith
                        xlabel xmax xmin
                        y2label y2max y2min
                        ylabel ymax ymin
                        zlabel zmax zmin
                        cbmin cbmax);
my %plotOptionsSet;
foreach(@allPlotOptions) { $plotOptionsSet{$_} = 1; }

my @allCurveOptions = qw(legend y2 with tuplesize);
my %curveOptionsSet;
foreach(@allCurveOptions) { $curveOptionsSet{$_} = 1; }


# get a list of all the -- options that this gnuplot supports
my %gnuplotFeatures = _getGnuplotFeatures();



sub new
{
  my $classname = shift;

  my %plotoptions = ();
  if(@_)
  {
    if(ref $_[0])
    {
      if(@_ != 1)
      {
        barf "PDL::Graphics::Gnuplot->new() got a ref as a first argument and has OTHER arguments. Don't know what to do";
      }

      %plotoptions = %{$_[0]};
    }
    else
    { %plotoptions = @_; }
  }

  if( my @badKeys = grep {!defined $plotOptionsSet{$_}} keys %plotoptions )
  {
    barf "PDL::Graphics::Gnuplot->new() got option(s) that were NOT a plot option: (@badKeys)";
  }

  my $pipe = startGnuplot( $plotoptions{dump} );
  print $pipe parseOptions(\%plotoptions);

  my $this = {pipe    => $pipe,
              options => \%plotoptions};
  bless($this, $classname);

  return $this;


  sub startGnuplot
  {
    # if we're simply dumping the gnuplot commands to stdout, simply return a handle to STDOUT
    my $dump = shift;
    return *STDOUT if $dump;


    my @options = $gnuplotFeatures{persist} ? qw(--persist) : ();

    my $pipe;
    open( $pipe, '|-', 'gnuplot', @options) or die "Couldn't run the 'gnuplot' backend";

    return $pipe;
  }

  sub parseOptions
  {
    my $options = shift;

    # set some defaults
    # plot with lines and points by default
    $options->{globalwith} = 'linespoints' unless defined $options->{globalwith};

    # make sure I'm not passed invalid combinations of options
    {
      if ( $options->{'3d'} )
      {
        if ( defined $options->{y2min} || defined $options->{y2max} )
        { barf "'3d' does not make sense with 'y2'...\n"; }
      }
      else
      {
        if ( defined $options->{square_xy} )
        { barf "'square'_xy only makes sense with '3d'\n"; }
      }
    }


    my $cmd   = '';

    # grid on by default
    if( !$options->{nogrid} )
    { $cmd .= "set grid\n"; }

    # set the plot bounds
    {
      # If a bound isn't given I want to set it to the empty string, so I can communicate it simply
      # to gnuplot
      $options->{xmin}  = '' unless defined $options->{xmin};
      $options->{xmax}  = '' unless defined $options->{xmax};
      $options->{ymin}  = '' unless defined $options->{ymin};
      $options->{ymax}  = '' unless defined $options->{ymax};
      $options->{y2min} = '' unless defined $options->{y2min};
      $options->{y2max} = '' unless defined $options->{y2max};
      $options->{zmin}  = '' unless defined $options->{zmin};
      $options->{zmax}  = '' unless defined $options->{zmax};
      $options->{cbmin} = '' unless defined $options->{cbmin};
      $options->{cbmax} = '' unless defined $options->{cbmax};

      # if any of the ranges are given, set the range
      $cmd .= "set xrange  [$options->{xmin} :$options->{xmax} ]\n" if length( $options->{xmin}  . $options->{xmax} );
      $cmd .= "set yrange  [$options->{ymin} :$options->{ymax} ]\n" if length( $options->{ymin}  . $options->{ymax} );
      $cmd .= "set zrange  [$options->{zmin} :$options->{zmax} ]\n" if length( $options->{zmin}  . $options->{zmax} );
      $cmd .= "set cbrange [$options->{cbmin}:$options->{cbmax}]\n" if length( $options->{cbmin} . $options->{cbmax} );
      $cmd .= "set y2range [$options->{y2min}:$options->{y2max}]\n" if length( $options->{y2min} . $options->{y2max} );
    }

    # set the curve labels, titles
    {
      $cmd .= "set xlabel  \"$options->{xlabel }\"\n" if defined $options->{xlabel};
      $cmd .= "set ylabel  \"$options->{ylabel }\"\n" if defined $options->{ylabel};
      $cmd .= "set zlabel  \"$options->{zlabel }\"\n" if defined $options->{zlabel};
      $cmd .= "set y2label \"$options->{y2label}\"\n" if defined $options->{y2label};
      $cmd .= "set title   \"$options->{title  }\"\n" if defined $options->{title};
    }

    # handle a requested square aspect ratio
    {
      # set a square aspect ratio. Gnuplot does this differently for 2D and 3D plots
      if ( $options->{'3d'})
      {
        if    ($options->{square})    { $cmd .= "set view equal xyz\n"; }
        elsif ($options->{square_xy}) { $cmd .= "set view equal xy\n" ; }
      }
      else
      {
        if( $options->{square} ) { $cmd .= "set size ratio -1\n"; }
      }
    }

    # handle hardcopy output
    {
      if ( $options->{hardcopy})
      {
        my $outputfile = $options->{hardcopy};
        my ($outputfileType) = $outputfile =~ /\.(eps|ps|pdf|png)$/;
        if (!$outputfileType)
        { barf "Only .eps, .ps, .pdf and .png hardcopy output supported\n"; }

        my %terminalOpts =
          ( eps  => 'postscript solid color enhanced eps',
            ps   => 'postscript solid color landscape 10',
            pdf  => 'pdfcairo solid color font ",10" size 11in,8.5in',
            png  => 'png size 1280,1024' );

        $cmd .= "set terminal $terminalOpts{$outputfileType}\n";
        $cmd .= "set output \"$outputfile\"\n";
      }
    }


    # add the extra global options
    {
      if($options->{extracmds})
      {
        # if there's a single extracmds option, put it into a 1-element list to
        # make the processing work
        if(!ref $options->{extracmds} )
        { $options->{extracmds} = [$options->{extracmds}]; }

        foreach (@{$options->{extracmds}})
        { $cmd .= "$_\n"; }
      }
    }

    return $cmd;
  }
}

# the main API function to generate a plot. Input arguments are a bunch of
# piddles optionally preceded by a bunch of options for each curve. See the POD
# for details
sub plot
{
  barf( "Plot called with no arguments") unless @_;

  my $this;

  if(!defined ref $_[0] || ref $_[0] ne 'PDL::Graphics::Gnuplot')
  {
    # plot() called as a global function, NOT as a method.  the first argument
    # can be a hashref of plot options, or it could be the data directly.
    my $plotOptions = {};

    if(defined ref $_[0] && ref $_[0] eq 'HASH')
    {
      # first arg is a hash. Is it plot options or curve options?
      my $NmatchedPlotOptions = grep {defined $plotOptionsSet{$_}} keys %{$_[0]};

      if($NmatchedPlotOptions != 0)
      {
        if($NmatchedPlotOptions != scalar keys %{$_[0]})
        {
          barf "Got an option hash that isn't completely plot options or non-plot options";
        }

        $plotOptions = shift;
      }
    }
    else
    {
      # first arg is NOT a hashref. It could be an inline hash. I now grab the hash
      # elements one at a time as long as they're plot options
      while( @_ >= 2 && $plotOptionsSet{$_[0]} )
      {
        my $key = shift;
        my $val = shift;
        $plotOptions->{$key} = $val;
      }
    }

    $this = $globalPlot = PDL::Graphics::Gnuplot->new($plotOptions);
  }
  else
  {
    $this = shift;
  }

  my $pipe        = $this->{pipe};
  my $plotOptions = $this->{options};


  # I split my data-to-plot into similarly-styled chunks
  # pieces of data we're plotting. Each chunk has a similar style
  my ($chunks, $Ncurves) = parseArgs($plotOptions->{'3d'}, @_);


  if( scalar @$chunks == 0)
  { barf "plot() was not given any data"; }


  say $pipe plotcmd($chunks, $plotOptions->{'3d'}, $plotOptions->{globalwith});

  foreach my $chunk(@$chunks)
  {
    my $data      = $chunk->{data};
    my $tupleSize = scalar @$data;
    eval( "_writedata_$tupleSize" . '(@$data, $pipe)');
  }

  flush $pipe;


  # generates the gnuplot command to generate the plot. The curve options are parsed here
  sub plotcmd
  {
    my ($chunks, $is3d, $globalwith) = @_;

    my $cmd = '';


    # if anything is to be plotted on the y2 axis, set it up
    if( grep {my $chunk = $_; grep {$_->{y2}} @{$chunk->{options}}} @$chunks)
    {
      if ( $is3d )
      { barf "3d plots don't have a y2 axis"; }

      $cmd .= "set ytics nomirror\n";
      $cmd .= "set y2tics\n";
    }

    if($is3d) { $cmd .= 'splot '; }
    else      { $cmd .= 'plot ' ; }

    $cmd .=
      join(',',
           map
           { map {"'-' " . optioncmd($_, $globalwith)} @{$_->{options}} }
           @$chunks);

    return $cmd;



    # parses a curve option
    sub optioncmd
    {
      my $option     = shift;
      my $globalwith = shift;

      my $cmd = '';

      if( defined $option->{legend} )
      { $cmd .= "title \"$option->{legend}\" "; }
      else
      { $cmd .= "notitle "; }

      # use the given per-curve 'with' style if there is one. Otherwise fall
      # back on the global
      my $with = $option->{with} || $globalwith;

      $cmd .= "with $with " if $with;
      $cmd .= "axes x1y2 "  if $option->{y2};

      return $cmd;
    }
  }

  sub parseArgs
  {
    # Here I parse the plot() arguments.  Each chunk of data to plot appears in
    # the argument list as plot(options, options, ..., data, data, ....). The
    # options are a hashref, an inline hash or can be absent entirely. THE
    # OPTIONS ARE ALWAYS CUMULATIVELY DEFINED ON TOP OF THE PREVIOUS SET OF
    # OPTIONS (except the legend)
    # The data arguments are one-argument-per-tuple-element.
    my $is3d = shift;
    my @args = @_;

    # options are cumulative except the legend (don't want multiple plots named
    # the same). This is a hashref that contains the accumulator
    my $lastOptions = {};

    my @chunks;
    my $Ncurves  = 0;
    my $argIndex = 0;
    while($argIndex <= $#args)
    {
      # First, I find and parse the options in this chunk
      my $nextDataIdx = first {ref $args[$_] && ref $args[$_] eq 'PDL'} $argIndex..$#args;
      last if !defined $nextDataIdx; # no more data. done.

      # I do not reuse the curve legend, since this would result it multiple
      # curves with the same name
      delete $lastOptions->{legend};

      my %chunk;
      if( $nextDataIdx > $argIndex )
      {
        $chunk{options} = parseOptionsArgs($lastOptions, @args[$argIndex..$nextDataIdx-1]);

        # make sure I know what to do with all the options
        foreach my $option (@{$chunk{options}})
        {
          if (my @badKeys = grep {!defined $curveOptionsSet{$_}} keys %$option)
          {
            barf "plot() got some unknown curve options: (@badKeys)";
          }
        }
      }
      else
      {
        # No options given for this chunk, so use the last ones
        $chunk{options} = [ dclone $lastOptions ];
      }

      # I now have the options for this chunk. Let's grab the data
      $argIndex         = $nextDataIdx;
      my $nextOptionIdx = first {!ref $args[$_] || ref $args[$_] ne 'PDL'} $argIndex..$#args;
      $nextOptionIdx = @args unless defined $nextOptionIdx;

      my $tupleSize    = getTupleSize($is3d, $chunk{options});
      my $NdataPiddles = $nextOptionIdx - $argIndex;

      if($NdataPiddles > $tupleSize)
      {
        $nextOptionIdx = $argIndex + $tupleSize;
        $NdataPiddles  = $tupleSize;
      }

      my @dataPiddles   = @args[$argIndex..$nextOptionIdx-1];

      if($NdataPiddles < $tupleSize)
      {
        # I got fewer data elements than I expected

        if(!$is3d && $NdataPiddles+1 == $tupleSize)
        {
          # A 2D plot is one data element short. Fill in a sequential domain
          # 0,1,2,...
          unshift @dataPiddles, sequence($dataPiddles[0]->dim(0));
        }
        elsif($is3d && $NdataPiddles+2 == $tupleSize)
        {
          # a 3D plot is 2 elements short. Use a grid as a domain
          my @dims = $dataPiddles[0]->dims();
          if(@dims < 2)
          { barf "plot() tried to build a 2D implicit domain, but not the first data piddle is too small"; }

          # grab the first 2 dimensions to build the x-y domain
          splice @dims, 2;
          my $x = zeros(@dims)->xvals->clump(2);
          my $y = zeros(@dims)->yvals->clump(2);
          unshift @dataPiddles, $x, $y;

          # un-grid the data-to plot to match the new domain
          foreach my $data(@dataPiddles)
          { $data = $data->clump(2); }
        }
        else
        { barf "plot() needed $tupleSize data piddles, but only got $NdataPiddles"; }
      }

      $chunk{data}      = \@dataPiddles;

      $chunk{Ncurves} = countCurvesAndValidate(\%chunk);
      $Ncurves += $chunk{Ncurves};

      push @chunks, \%chunk;

      $argIndex = $nextOptionIdx;
    }

    return (\@chunks, $Ncurves);




    sub parseOptionsArgs
    {
      # my options are cumulative, except the legend. This variable contains the accumulator
      my $options = shift;

      # I now have my options arguments. Each curve is described by a hash
      # (reference or inline). To have separate options for each curve, I use an
      # ref to an array of hashrefs
      my @optionsArgs = @_;

      # the options for each curve go here
      my @curveOptions = ();

      my $optionArgIdx = 0;
      while ($optionArgIdx < @optionsArgs)
      {
        my $optionArg = $optionsArgs[$optionArgIdx];

        if (ref $optionArg)
        {
          if (ref $optionArg eq 'HASH')
          {
            # add this hashref to the options
            @{$options}{keys %$optionArg} = values %$optionArg;
            push @curveOptions, dclone($options);

            # I do not reuse the curve legend, since this would result it multiple
            # curves with the same name
            delete $options->{legend};
          }
          else
          {
            barf "plot() got a reference to a " . ref( $optionArg) . ". I can only deal with HASHes and ARRAYs";
          }

          $optionArgIdx++;
        }
        else
        {
          my %unrefedOptions;
          do
          {
            $optionArg = $optionsArgs[$optionArgIdx];

            # this is a scalar. I interpret a pair as key/value
            if ($optionArgIdx+1 == @optionsArgs)
            { barf "plot() got a lone scalar argument $optionArg, where a key/value was expected"; }

            $options->{$optionArg} = $optionsArgs[++$optionArgIdx];
            $optionArgIdx++;
          } while($optionArgIdx < @optionsArgs && !ref $optionsArgs[$optionArgIdx]);
          push @curveOptions, dclone($options);

          # I do not reuse the curve legend, since this would result it multiple
          # curves with the same name
          delete $options->{legend};
        }

      }

      return \@curveOptions;
    }

    sub countCurvesAndValidate
    {
      my $chunk = shift;

      # Make sure the domain and ranges describe the same number of data points
      my $data = $chunk->{data};
      foreach (1..$#$data)
      {
        my $dim0 = $data->[$_  ]->dim(0);
        my $dim1 = $data->[$_-1]->dim(0);
        if( $dim0 != $dim1 )
        { barf "plot() was given mismatched tuples to plot. $dim0 vs $dim1"; }
      }

      # I now make sure I have exactly one set of curve options per curve
      my $Ncurves = countCurves($data);
      my $Noptions = scalar @{$chunk->{options}};

      if($Noptions > $Ncurves)
      { barf "plot() got $Noptions options but only $Ncurves curves. Not enough curves"; }
      elsif($Noptions < $Ncurves)
      {
        # I have more curves then options. I pad the option list with the last
        # option, removing the legend
        my $lastOption = dclone $chunk->{options}[-1];
        delete $lastOption->{legend};
        push @{$chunk->{options}}, ($lastOption) x ($Ncurves - $Noptions);
      }

      return $Ncurves;



      sub countCurves
      {
        # compute how many curves have been passed in, assuming things thread

        my $data = shift;

        my $N = 1;

        # I need to look through every dimension to check that things can thread
        # and then to compute how many threads there will be. I skip the first
        # dimension since that's the data points, NOT separate curves
        my $maxNdims = List::Util::max map {$_->ndims} @$data;
        foreach my $dimidx (1..$maxNdims-1)
        {
          # in a particular dimension, there can be at most 1 non-1 unique
          # dimension. Otherwise threading won't work.
          my $nonDegenerateDim;

          foreach (@$data)
          {
            my $dim = $_->dim($dimidx);
            if($dim != 1)
            {
              if(defined $nonDegenerateDim && $nonDegenerateDim != $dim)
              {
                barf "plot() was given non-threadable arguments. Got a dim of size $dim, when I already saw size $nonDegenerateDim";
              }
              else
              {
                $nonDegenerateDim = $dim;
              }
            }
          }

          # this dimension checks out. Count up the curve contribution
          $N *= $nonDegenerateDim if $nonDegenerateDim;
        }

        return $N;
      }
    }

    sub getTupleSize
    {
      my $is3d    = shift;
      my $options = shift;

      # I have a list of options for a set of curves in a chunk. Inside a chunk
      # the tuple set MUST be the same. I.e. I can have 2d data in one chunk and
      # 3d data in another, but inside a chunk it MUST be consistent
      my $size;
      foreach my $option (@$options)
      {
        my $sizehere;

        if ($option->{tuplesize})
        {
          # if we have a given tuple size, just use it
          $sizehere = $option->{tuplesize};
        }
        else
        {
          $sizehere = $is3d ? 3 : 2; # given nothing else, use ONLY the geometrical plotting
        }

        if(!defined $size)
        { $size = $sizehere;}
        else
        {
          if($size != $sizehere)
          {
            barf "plot() tried to change tupleSize in a chunk: $size vs $sizehere";
          }
        }
      }

      return $size;
    }
  }
}

# subroutine to write the columns of some piddles into a gnuplot stream. This
# assumes the last argument is a file handle. Generally you should NOT be using
# this directly at all; it's just used to define the threading-aware routines
sub _wcols_gnuplot
{
  wcols @_;
  my $pipe = $_[-1];
  say $pipe 'e';
};

# I generate a bunch of PDL definitions such as
# _writedata_2(x1(n), x2(n)), NOtherPars => 1
# 20 tuples per point sounds like plenty. The most complicated plots Gnuplot can
# handle probably max out at 5 or so
for my $n (2..20)
{
  my $def = "_writedata_$n(" . join( ';', map {"x$_(n)"} 1..$n) . "), NOtherPars => 1";
  thread_define $def, over \&_wcols_gnuplot;
}


sub _getGnuplotFeatures
{
  open(GNUPLOT, 'gnuplot --help |') or die "Couldn't run the 'gnuplot' backend";

  local $/ = undef;
  my $in = <GNUPLOT>;

  my @features = $in =~ /--([a-zA-Z0-9_]*)/g;

  my %featureSet;
  foreach (@features) { $featureSet{$_} = 1; }

  return %featureSet;
}

1;


__END__


=head1 NAME

PDL::Graphics::Gnuplot - Gnuplot-based plotter for PDL

=head1 SYNOPSIS

 use PDL::Graphics::Gnuplot qw(plot);

 my $x = sequence(101) - 50;
 plot($x**2);

 plot( title => 'Parabola with error bars',
       with => 'xyerrorbars', tuplesize => 4, legend => 'Parabola',
       $x**2 * 10, abs($x)/10, abs($x)*5 );

 my $xy = zeros(21,21)->ndcoords - pdl(10,10);
 my $z = inner($xy, $xy);
 plot(title  => 'Heat map', '3d' => 1,
      extracmds => 'set view 0,0',
      {with => 'image',tuplesize => 3}, $z*2);

 my $pi    = 3.14159;
 my $theta = zeros(200)->xlinvals(0, 6*$pi);
 my $z     = zeros(200)->xlinvals(0, 5);
 plot( '3d' => 1,
       cos($theta), sin($theta), $z);


=head1 DESCRIPTION

This module allows PDL data to be plotted using Gnuplot as a backend. As much as
was possible, this module acts as a passive pass-through to Gnuplot, thus making
available the full power and flexibility of the Gnuplot backend.

The main subroutine that C<PDL::Graphics::Gnuplot> exports is C<plot()>. A call
to C<plot()> looks like

 plot(plot_options,
      curve_options, data, data, ... ,
      curve_options, data, data, ... );

=head2 Options arguments

Each set of options is a hash that can be passed inline or as a hashref: both
C<plot( title =E<gt> 'Fancy plot!', ... )> and C<plot( {title =E<gt> 'Another fancy
plot'}, ...)> work. The plot options I<must> precede all the curve options.

The plot options are parameters that affect the whole plot, like the title of
the plot, the axis labels, the extents, 2d/3d selection, etc. All the plot
options are described below in L</"Plot options">.

The curve options are parameters that affect only one curve in particular. Each
call to C<plot()> can contain many curves, and options for a particular curve
I<precede> the data for that curve in the argument list. Furthermore, I<curve
options are all cumulative>. So if you set a particular style for a curve, this
style will persist for all the following curves, until this style is turned
off. The only exception to this is the C<legend> option, since it's very rarely
a good idea to have multiple curves with the same label. An example:

 plot( with => 'points', $x, $a,
       y2   => 1,        $x, $b,
       with => 'lines',  $x, $c );

This plots 3 curves: $a vs. $x plotted with points on the main y-axis (this is
the default), $b vs. $x plotted with points on the secondary y axis, and $c
vs. $x plotted with lines also on the secondary y axis. All the curve options
are described below in L</"Curve options">.

=head2 Data arguments

Following the curve options in the C<plot()> argument list is the actual data
being plotted. Each output data point is a tuple whose size varies depending on
what is being plotted. For example if we're making a simple 2D x-y plot, each
tuple has 2 values; if we're making a 3d plot with each point having variable
size and color, each tuple has 5 values (x,y,z,size,color). In the C<plot()>
argument list each tuple element must be passed separately. If we're making
anything fancier than a simple 2D or 3D plot (2- and 3- tuples respectively)
then the C<tuplesize> curve option I<must> be passed in. Furthermore, PDL
threading is active, so multiple curves can be plotted by stacking data inside
the passed-in piddles. When doing this, multiple sets of curve options can be
passed in as multiple hashrefs preceding the data itself in the argument
list. By using hashrefs we can make clear which option corresponds to which
plot. An example:

 my $pi    = 3.14159;
 my $theta = zeros(200)->xlinvals(0, 6*$pi);
 my $z     = zeros(200)->xlinvals(0, 5);

 plot( '3d' => 1, title => 'double helix',

       { with => 'points pointsize variable pointtype 7 palette', tuplesize => 5,
         legend => 'spiral 1' },
       { legend => 'spiral 2' },

       # 2 sets of x, 2 sets of y, single z:
       PDL::cat( cos($theta), -cos($theta)),
       PDL::cat( sin($theta), -sin($theta)),
       $z,

       # pointsize, color
       0.5 + abs(cos($theta)), sin(2*$theta) );

This is a 3d plot with variable size and color. There are 5 values in the tuple,
which we specify. The first 2 piddles have dimensions (N,2); all the other
piddles have a single dimension. Thus the PDL threading generates 2 distinct
curves, with varying values for x,y and identical values for everything else. To
label the curves differently, 2 different sets of curve options are given. Since
the curve options are cumulative, the style and tuplesize needs only to be
passed in for the first curve; the second curve inherits those options.


=head3 Implicit domains

When a particular tuplesize is specified, PDL::Graphics::Gnuplot will attempt to
read that many piddles. If there aren't enough piddles available,
PDL::Graphics::Gnuplot will throw an error, unless an implicit domain can be
used. This happens if we are I<exactly> 1 piddle short when plotting in 2D or 2
piddles short when plotting in 3D.

When making a simple 2D plot, if exactly 1 dimension is missing,
PDL::Graphics::Gnuplot will use C<sequence(N)> as the domain. This is why code
like C<plot(pdl(1,5,3,4,4) )> works. Only one piddle is given here, but a
default tuplesize of 2 is active, and we are thus exactly 1 piddle short. This
is thus equivalent to C<plot( sequence(5), pdl(1,5,3,4,4) )>.

If plotting in 3d, an implicit domain will be used if we are exactly 2 piddles
short. In this case, PDL::Graphics::Gnuplot will use a 2D grid as a
domain. Example:

 my $xy = zeros(21,21)->ndcoords - pdl(10,10);
 plot('3d' => 1,
       with => 'points', inner($xy, $xy));

Here the only given piddle has dimensions (21,21). This is a 3D plot, so we are
exactly 2 piddles short. Thus, PDL::Graphics::Gnuplot generates an implicit
domain, corresponding to a 21-by-21 grid.

One thing to watch out for it to make sure PDL::Graphics::Gnuplot doesn't get
confused about when to use implicit domains. For example, C<plot($a,$b)> is
interpreted as plotting $b vs $a, I<not> $a vs an implicit domain and $b vs an
implicit domain. If 2 implicit plots are desired, add a separator:
C<plot($a,{},$b)>. Here C<{}> is an empty curve options hash. If C<$a> and C<$b>
have the same dimensions, one can also do C<plot($a->cat($b))>, taking advantage
of PDL threading.

Note that the C<tuplesize> curve option is independent of implicit domains. This
option specifies not how many data piddles we have, but how many values
represent each data point. For example, if we want a 2D plot with varying colors
plotted with an implicit domain, set C<tuplesize> to 3 as before, but pass in
only 2 piddles (y, color).

=head2 Interactivity

The default backend Gnuplot uses to generate the plots is interactive, allowing
the user to pan, zoom, rotate and measure the data in the plot window. See the
Gnuplot documentation for details about how to do this. One thing to note with
PDL::Graphics::Gnuplot is that the interactivity is only possible if the gnuplot
process is running. As long as the perl program calling PDL::Graphics::Gnuplot
is running, the plots are interactive, but once it exits, the child gnuplot
process will exit also. This will keep the plot windows up, but the
interactivity will be lost. So if the perl program makes a plot and exits, the
plot will NOT be interactive.

Due to particulars of the current implementation of PDL::Graphics::Gnuplot, each
time C<plot()> is called, a new gnuplot process is launched, killing the
previous one. This results only in the latest plot being interactive. The way to
resolve this is to use the object-oriented interface to PDL::Graphics::Gnuplot
(see L</"Exports"> below).


=head1 DETAILS

=head2 Exports

Currently there's one importable subroutine: C<plot()>. Each C<plot()> call
creates a new plot in a new window. There's also an object-oriented interface
that can be used like so:

  my $plot = PDL::Graphics::Gnuplot->new(title => 'Object-oriented plot');
  $plot->plot( legend => 'curve', sequence(5) );

The plot options are passed into the constructor; the curve options and the data
are passed into the method. One advantage of making plots this way is that
there's a gnuplot process associated with each PDL::Graphics::Gnuplot instance,
so as long as C<$plot> exists, the plot will be interactive. Also, calling
C<$plot-E<gt>plot()> multiple times reuses the plot window instead of creating a
new one.


=head2 Plot options

The plot options are a hash, passed as the initial arguments to the global
C<plot()> subroutine or as the only arguments to the PDL::Graphics::Gnuplot
contructor. The supported keys of this hash are as follows:

=over 2

=item title

Specifies the title of the plot

=item 3d

If true, a 3D plot is constructed. This changes the default tuple size from 2 to
3

=item nogrid

By default a grid is drawn on the plot. If this option is true, this is turned off

=item globalwith

If no valid 'with' curve option is given, use this as a default

=item square, square_xy

If true, these request a square aspect ratio. For 3D plots, square_xy plots with
a square aspect ratio in x and y, but scales z

=item xmin, xmax, ymin, ymax, zmin, zmax, y2min, y2max, cbmin, cbmax

If given, these set the extents of the plot window for the requested axes. The
y2 axis is the secondary y-axis that is enabled by the 'y2' curve option. The
'cb' axis represents the color axis, used when color-coded plots are being
generated

=item xlabel, ylabel, zlabel, y2label

These specify axis labels

=item hardcopy

Instead of drawing a plot on screen, plot into a file instead. The output
filename is the value associated with this key. The output format is inferred
from the filename. Currently only eps, ps, pdf, png are supported with some
default sets of options. This may become more configurable later

=item extracmds

Arbitrary extra commands to pass to gnuplot before the plots are created. These
are passed directly to gnuplot, without any validation. The value is either a
string of an arrayref of different commands

=item dump

Used for debugging. If true, writes out the gnuplot commands to STDOUT instead
of writing to a gnuplot process

=back


=head2 Curve options

The curve options describe details of specific curves. They are in a hash, whose
keys are as follows:

=over 2

=item legend

Specifies the legend label for this curve

=item with

Specifies the style for this curve. The value is passed to gnuplot using its
'with' keyword, so valid values are whatever gnuplot supports. Read the gnuplot
documentation for the 'with' keyword for more information

=item y2

If true, requests that this curve be plotted on the y2 axis instead of the main y axis

=item tuplesize

Specifies how many values represent each data point. For 2D plots this defaults
to 2; for 3D plots this defaults to 3.

=back


=head1 REPOSITORY

L<https://github.com/dkogan/PDL-Graphics-Gnuplot>

=head1 AUTHOR

Dima Kogan, C<< <dima@secretsauce.net> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 Dima Kogan.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

