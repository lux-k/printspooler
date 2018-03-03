#!/usr/bin/perl
# Kevin Lux
# http://kevinlux.info/
# takes data files, transforms them in to a format appropriate for printing to
# a label printer and then sends the print job over tcp
# this spooler works on both windows and linux. essentially, it watches a 
# directory for txt files which it then processes according to rules
# in the label configuration file

$| = 1;
use IO::Socket;
use strict;

# where to look for files to be processed
my $dir = "p:/";
# how many seconds to wait before checking for new files to be processed
my $stime = 5;
my $lc = new LabelConfig('labels.conf');
open(FILE, ">spooler.pid");
print FILE $$;
close(FILE);

logmsg("spooler is online");

while (1) {
	my @timedata = localtime(time);
	if ($timedata[0] <= $stime && $timedata[1] == 0) {
		#write out statistics
		print "\nRunning daily summary\n";
		for (my $i = 0; $i < $lc->labelcount; $i++) {
			print $lc->labels->[$i]->name . " : " . $lc->labels->[$i]->printed . "\n";
			if ($timedata[2] == 0) {
				$lc->labels->[$i]->printed(0); 
			}
		}
		print "End of summary\n\n";
	}

	# poll the directory
	my @files;
	if ( opendir(DIR, $dir) ) {
		@files = grep { /\.txt$/} readdir(DIR);
		close(DIR);
	} else {
		logmsg("Can't access $dir");
	}

	# for each file found...
	foreach my $file (sort @files) {
		logmsg("processing $file");
		my $err = 0;
		open(FILE, $dir . '/' . $file) || die "can't read $dir/$file!";
		my @lines= <FILE>;
		close(FILE);
		chomp(@lines);
		
		# load the user information
		my %user;
		my $i = 0;
		while ($lines[$i] ne '') {
			parseline(\%user, $lines[$i++]);
		}
		
		# process the labels
		$i++;
		while ($i < $#lines) {
			my %label;
			while ($lines[$i] ne '' && $i < $#lines) {
				parseline(\%label, $lines[$i++]);
			}

			foreach my $key (keys %user) {
				$label{$key} = $user{$key};
			}

			# label is read in here
			my $l = $lc->findlabel(\%label);
			my $errorcount = 0;
			if ($l) {
				PRINT:
				print "Matches template " . $l->name . "\n";
				my $output = $l->makelabel(\%label);
				print "Send to " . $l->printer . "\n";
				eval {
					my $remote = IO::Socket::INET->new(Proto=>"tcp", PeerAddr=>$l->printerip, PeerPort=>$l->printerport, Reuse=>1)
					    or die "Can't connect to " . $l->printerip . ':' . $l->printerport;
					print $remote $output;
					close $remote;
					sleep 1;
					$l->printed($l->printed + 1);
				};
				if ($@) {
					logmsg("$@");
					$errorcount++;
					sleep 3;
					if ($errorcount >= 5) {
						$err = 1;
					} else {
						goto PRINT;
					}
				}
					
			} else {
				logmsg("No label found");
			}
			$i++;
		}

		unlink($dir . '/' . $file) unless $err;
		logmsg("processing $file: complete");
	}

	sleep $stime;
}

sub parseline {
	my ($hashref, $line) = @_;
	$line =~ m/^(.+?)=(.+)$/;
	$hashref->{lc($1)} = $2;
}


sub logmsg {
	my $msg = "@_";
	$msg =~ s/\r?\n$//g;
	print "$0 $$ [", scalar localtime,"]: ", $msg , "\n";
}

package Label;

sub new {
	my $self = shift;
	$self = {};
	$self->{PRINTERPORT} = 9000;
	$self->{PRINTED} = 0;
	bless($self);
	return $self;
}

sub name {
	my ($self, $n) = @_;
	$self->{NAME} = $n unless !$n;
	return $self->{NAME};
}

sub reqs {
	my ($self, $n) = @_;
	if ($n) {
		my @arr = split(/; */, $n);
		$self->{REQS} =  \@arr;
	}
	return $self->{REQS};
}

sub printed {
	my ($self, $n) = @_;
	$self->{PRINTED} = $n unless !defined($n);
	return $self->{PRINTED};
}

sub printer {
	my ($self, $n) = @_;
	$self->{PRINTER} = $n unless !$n;
	if ($n) {
		my ($pr, $pp) = split(/:/, $n);
		$self->{PRINTERIP} = $pr;
		$self->{PRINTERPORT} = $pp;
	}
	return $self->{PRINTER};
}

sub printerport {
	my ($self, $n) = @_;
	$self->{PRINTERPORT} = $n unless !$n;
	return $self->{PRINTERPORT};
}

sub printerip {
	my ($self, $n) = @_;
	$self->{PRINTERIP} = $n unless !$n;
	return $self->{PRINTERIP};
}

sub label {
	my ($self, $n) = @_;
	$self->{LABEL} = $n unless !$n;
	return $self->{LABEL};
}

sub code {
	my ($self, $n) = @_;
	$n =~ s/(\{\{(.+?)\}\})/\$label{$2}/g;
	$self->{CODE} = $n unless !$n;
	return $self->{CODE};
}

sub eval {
	my ($self, $parms)= @_;
	my $ret = 1;

	foreach my $cond ( @{$self->{REQS}}) {
		my $c = $cond;
		$c =~ s/\{\{(.+?)\}\}/\$parms->\{'$1'\}/g;
		#print "$c -> " . eval($c) . "\n";
		$ret &= eval $c;
	}

	return $ret;
}

sub makelabel {
	my ($self, $l) = @_;
	my $template = $self->label;
	my %label = %{$l};
	eval $self->code;
	$template =~ s/(\{\{(.+?)\}\})/$label{lc($2)}/ge;
	print $template;
	return $template;
}

END;

package LabelConfig;

sub new {
	my $self = shift;
	my $file = shift;
	die "Need config file" unless $file;
	$self = {};
	$self->{LABELS} = ();
	bless($self);
	$self->loadconfig($file);
	return $self;
}

sub loadconfig {
	my ($self, $file) = @_;
	open(FILE, $file) || die "Can't open $file";
	my @lines = <FILE>;
	chomp(@lines);
	close(FILE);
	@lines = grep { $_ !~ m/^#/ } @lines;

	#name
	#code
	#criteria
	#printer
	#label data
	for (my $i = 0; $i < $#lines; $i++) {
		my $l = new Label();
		$l->name($lines[$i++]);
		print "Loading config for " . $l->name . "...";
		$l->code($lines[$i++]);
		$l->reqs($lines[$i++]);
		if ($lines[$i++] eq '') {
			die "No IP/port specified for " . $l->name;
		}
		$l->printer($lines[$i-1]);
		my $label = '';
		while ($lines[$i] ne '') {
			$label .= $lines[$i++] . "\n";
		}
		$l->label($label);
		push(@{$self->{LABELS}}, $l);
		print " done.\n";
	}
	print "\n";
}

sub labelcount {
	my $self = shift;
	return scalar(@{$self->{LABELS}});
}

sub labels {
	my $self = shift;
	return $self->{LABELS};
}

sub findlabel {
	my $self = shift;
	my $parms = shift;
	for (my $i = 0; $i < $self->labelcount; $i++) {
		if (@{$self->{LABELS}}->[$i]->eval($parms)) {
			return @{$self->{LABELS}}->[$i];
		}
	}
}

END;


