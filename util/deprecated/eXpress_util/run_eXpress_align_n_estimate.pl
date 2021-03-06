#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;

use Cwd;

use Getopt::Long qw(:config no_ignore_case bundling);


my $usage = <<__EOUSAGE__;

#########################################################################
#
#  --transcripts <string>           transcript fasta file
#  --seqType <string>              fq|fa
# 
#  If Paired-end:
#
#  --left <string>
#  --right <string>
#  
#    or Single-end:
#
#  --single <string>
#
#
#
# Optional:
# 
# --pipe                           pipe directly into eXpress, don't generate intermediate bam file.
#
# --SS_lib_type <string>           strand-specific library type:  paired('RF' or 'FR'), single('F' or 'R').
#
# --no_group_by_component          Not Trinity transcripts (use --gene_trans_map to specify gene/trans relationships)
#
# --thread_count                   number of threads to use (default = 4)
#
# --debug                          retain intermediate files
#
# --output_dir <string>            write all files to output directory
#  
#####################
#  Non-Trinity options:
#
#  --gene_trans_map <string>        file containing 'gene(tab)transcript' identifiers per line.
#
#  --just_prep_reference            only prep reference set for eXpress (builds bowtie index, etc)
#
#########################################################################


__EOUSAGE__

    ;


my $output_dir;
my $help_flag;
my $transcripts;
my $bam_file;
my $paired_flag;
my $DEBUG_flag = 0;
my $SS_lib_type;
my $no_group_by_component = 0;
my $thread_count = 4;
my $seqType;
my $left;
my $right;
my $single;
my $gene_trans_map_file;
my $pipe;

# devel opts
my $__just_prep_reference = 0;



&GetOptions ( 'h' => \$help_flag,
              'transcripts=s' => \$transcripts,
              'name_sorted_bam=s' => \$bam_file,
              'paired' => \$paired_flag,
              'debug' => \$DEBUG_flag,
              'SS_lib_type=s' => \$SS_lib_type,
              'no_group_by_component' => \$no_group_by_component,
              'thread_count=i' => \$thread_count,
              'gene_trans_map=s' => \$gene_trans_map_file,

              'seqType=s' => \$seqType,
              'left=s' => \$left,
              'right=s' => \$right,
              'single=s' => \$single,
                            
              'output_dir=s' => \$output_dir,
      

              'pipe' => \$pipe,
              
              ##  devel opts
              'just_prep_reference' => \$__just_prep_reference,


        
              );



if ($help_flag) {
    die $usage;
}

unless (($__just_prep_reference && $transcripts) || ($transcripts && $seqType && ($single || ($left && $right))) ) {
    die $usage;
}

if ($output_dir) {
    $left = &create_full_path($left) if $left;
    $right = &create_full_path($right) if $right;
    $single = &create_full_path($single) if $single;
    
    $transcripts = &create_full_path($transcripts);

}

if ($left && $left =~ /\.gz$/) {
    $left = &add_zcat_gz($left);
}
if ($right && $right =~ /\.gz$/) {
    $right = &add_zcat_gz($right);
}
if ($single && $single =~ /\.gz$/) {
    $single = &add_zcat_gz($single);
}



if ($SS_lib_type) {
    unless ($SS_lib_type =~ /^(RF|FR|R|F)$/) {
        die "Error, do not recognize SS_lib_type: [$SS_lib_type]\n";
    }
    if ($left && $right && length($SS_lib_type) != 2 ) {
        die "Error, SS_lib_type [$SS_lib_type] is not compatible with paired reads";
    }
}

if ( $thread_count !~ /^\d+$/ ) {
    die "Error, --thread_count value must be an integer";
}



{  # check for RSEM installation in PATH 
    
    my $missing = 0;
    my @tools = qw(bowtie-build bowtie express);    
    foreach my $tool (@tools) {
        my $p = `which $tool`;
        unless ($p =~ /\w/) {
            warn("ERROR, cannot find $tool in PATH setting: $ENV{PATH}\n\n");
            $missing = 1;
        }
    }
    if ($missing) {
        die "Please be sure bowtie and express are installed and the utilities @tools are available via your PATH setting.\n";
    }
}

main: {

    my $cmd = "bowtie-build --offrate 1 $transcripts $transcripts.eXpress";
    
    unless (-s "$transcripts.eXpress.1.ebwt" && -e "$transcripts.eXpress.ok") { ## this step already run

        &process_cmd($cmd);

        &process_cmd("touch $transcripts.eXpress.ok"); # now know that it completed successfully for other runs to use.
    }
    
    if ($__just_prep_reference) {
        print STDERR "Only prepping reference. Stopping now.\n";
        exit(0);
    }

    ## go on to running bowtie and running RSEM
    
    if ($output_dir) {
        
        my $init_dir = cwd();
        
        system("mkdir -p $output_dir");
        chdir $output_dir or die "Error, cannot cd to output directory $output_dir";
    
    }

    my $read_type = ($seqType eq "fq") ? "-q" : "-f";
    
    ## run bowtie
    my $bowtie_cmd;
    if ($left && $right) {
        $bowtie_cmd = "bowtie $read_type -aS -p $thread_count -X 800 --offrate 1 $transcripts.eXpress -1 $left -2 $right";
    }
    else {
        $bowtie_cmd = "bowtie $read_type -aS -p $thread_count --offrate 1 $transcripts.eXpress $single";
    }


    my $SS_opt = "";
    if ($SS_lib_type) {
        if ($SS_lib_type eq "F") {
            $SS_opt = "--f-stranded";
        }
        elsif ($SS_lib_type eq "R") {
            $SS_opt = "--r-stranded";
        }
        elsif ($SS_lib_type eq "FR") {
            $SS_opt = "--fr-stranded";
        }
        elsif ($SS_lib_type eq "RF") {
            $SS_opt = "--rf-stranded";
        }
    }
    
    ## run eXpress
    my $express_cmd = "express $SS_opt $transcripts";
    
    
    if ($pipe) {

        my $cmd = "$bowtie_cmd | $express_cmd";
        &process_cmd($cmd);
        
    }
    else {
    
        my $cmd = "$bowtie_cmd | samtools view -Sb - > bowtie.bam";
        &process_cmd($cmd);
    
        $cmd = "$express_cmd bowtie.bam";

        &process_cmd($cmd);
    }
    

    exit(0);
}


####
sub process_cmd {
    my ($cmd) = @_;

    my $ret = system("bash", "-c", $cmd);

    if ($ret) {
        die "Error, cmd: $cmd died with ret: $ret";
    }
    
    return;
}


####
sub write_gene_to_trans_map_file {
    my ($transcripts_fasta_file) = @_;
    
        
    open (my $fh, $transcripts_fasta_file) or die "Error, cannot open file $transcripts_fasta_file";
    
    my $mapping_file = "$transcripts_fasta_file.component_to_trans_map";
    open (my $ofh, ">$mapping_file") or die "Error, cannot write to file: $mapping_file";
    
    while (<$fh>) {
        if (/>(comp\S+)/) {
            my $acc = $1;
            $acc =~ /^(comp\d+_c\d+)_seq\d+/ or die "Error, cannot parse the trinity component ID from $acc";
            my $comp_id = $1;
            print $ofh "$comp_id\t$acc\n";
        }
    }
    close $fh;
    close $ofh;

    return($mapping_file);
}


###
sub create_full_path {
    my ($file) = shift;
    if (ref($file) eq "ARRAY"){
        for (my $i=0;$i<scalar(@$file);$i++){
            $file->[$i] = &create_full_path($file->[$i]);
        }
        return @$file;
    }else{
        my $cwd = cwd();
        if ($file !~ m|^/|) { # must be a relative path
            $file = $cwd . "/$file";
        }
        return($file);
    }
}

####
sub add_zcat_gz {
    my ($file) = @_;

    $file = "<(zcat $file)";
    
    return($file);
}
