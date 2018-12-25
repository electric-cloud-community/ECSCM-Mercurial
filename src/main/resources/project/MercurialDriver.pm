####################################################################
#
# ECSCM::Mercurial::Driver  Object to represent interactions with 
#        Mercurial.
####################################################################
package ECSCM::Mercurial::Driver;
@ISA = (ECSCM::Base::Driver);
use ElectricCommander;
use Time::Local;
use XML::XPath;
use Cwd;
use File::Path;
use Getopt::Long;

$|=1;

if (!defined ECSCM::Base::Driver) {
    require ECSCM::Base::Driver;
}

if (!defined ECSCM::Mercurial::Cfg) {
    require ECSCM::Mercurial::Cfg;
}

####################################################################
# new - Object constructor for ECSCM::Mercurial::Driver
#
# Arguments:
#   - cmdr          previously initialized ElectricCommander handle
#   - name          name of this configuration
#
# Returns:
#   - none
#
####################################################################
sub new {
    my $this = shift;
    my $class = ref($this) || $this;

    my $cmdr = shift;
    my $name = shift;

    my $cfg = new ECSCM::Mercurial::Cfg($cmdr, $name);
    if ($name ne '') {
        my $sys = $cfg->getSCMPluginName();
        if ($sys ne 'ECSCM-Mercurial') { die 'SCM config $name is not type ECSCM-Mercurial'; }
    }

    my ($self) = new ECSCM::Base::Driver($cmdr,$cfg);

    bless ($self, $class);
    return $self;
}

####################################################################
# isImplemented - Checks which functions are implemented.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
####################################################################
sub isImplemented {
    my ($self, $method) = @_;
    
    if ($method eq 'getSCMTag' || 
        $method eq 'checkoutCode' || 
        $method eq 'apf_driver' || 
        $method eq 'cpf_driver') {
        return 1;
    } else {
        return 0;
    }
}

####################################################################
# get scm tag for sentry (continuous integration)
####################################################################

####################################################################
# getSCMTag - Get the latest changelist on this branch/client
#
# Arguments:
#   - none
#
# Returns:
#   - changeNumber - a string representing the last change sequence #
#   - changeTime   - a time stamp representing the time of last change 
#
####################################################################
sub getSCMTag {
    my ($self, $opts) = @_;

    # add configuration that is stored for this config
    my $name = $self->getCfg()->getName();
    my %row = $self->getCfg()->getRow($name);
    foreach my $k (keys %row) {
        $self->debug("Reading $k=$row{$k} from config");
        $opts->{$k}=$row{$k};
    }

    # Load userName and password from the credential
    ($opts->{mercurialUserName}, $opts->{mercurialPassword}) = 
        $self->retrieveUserCredential($opts->{credential}, 
        $opts->{mercurialUserName}, $opts->{mercurialPassword});

    if (length ($opts->{mercurialRepository}) == 0) {
        $self->issueWarningMsg ("*** No Mercurial Repository was specified for\n    $projectName:$scheduleName");
        return (undef,undef);
    }
    
    my $changesetNumber = $self->getLastSnapshotFromRemoteRepo($opts->{mercurialRepository});
    my $changeTimeStamp = 0;
    
    my $last = $opts->{LASTATTEMPTED};
    #check if the current version is different from the last/stored version
    if((defined $last && $last ne $changesetNumber) || $last eq ""){
        #once we know that a change was found it's time to get the new sources
        print join("\n",    "-----------------------",
                            "New changes were found!!",
                            "Previous change id: $last",
                            "New change id:      $changesetNumber",
                            "-----------------------",
                            )."\n";
            ($changesetNumber,$changeTimeStamp) = $self->getLastSnapshotFromLog($opts);
    }
    
    return ($changesetNumber,$changeTimeStamp);
}

##########################################################################
# getLastSnapshotFromLog
# 
# Get the last snapshot SHA number and timestamp using the git log command
#
# Args:
#   opts hash
#
# Return: 
#    $changeNumber       - snapshot SHA number
#    $changeTime         - timestamp
##########################################################################
sub getLastSnapshotFromLog{
    my ($self, $opts) = @_;
    $opts->{dest} = "." if (!$opts->{dest});
    $opts->{depot} = $opts->{mercurialRepository};
    #perform a checkout
    $self->checkoutCode($opts);
    
    if (!chdir $opts->{dest}) {
        print "could not change to directory $opts->{dest}\n";
        exit 1;
    }
    
    my $command = qq{hg log --template "{node|short}|{date}" -l 1 -b .};
    
    my $result = $self->RunCommand($command, {LogCommand => 1, LogResult => 1} );
    
    $result =~ m/(.*)\|(.*)\./;
    my ($changesetNumber,$changeTimeStamp) = ($1,$2);
    
    return ($changesetNumber, $changeTimeStamp);
    
}

##################################################################
# getLastSnapshotFromRemoteRepo
# 
# Get the last snapshot SHA number using the git ls-remote command
#
# Args:
#   opts hash
#
# Return: 
#    $changeNumber       - snapshot id number
##################################################################
sub getLastSnapshotFromRemoteRepo{
    my ($self, $remote_repo) = @_;
    # get changeset id from remote server
    #output example:
    #46fa5d393237
    #
    my $command = "hg id -i $remote_repo";
    my $changesetNumber = $self->RunCommand($command, {LogCommand => 1, LogResult => 1} );
    
    #remove the newline character from the end of the string
    chomp($changesetNumber);
    return $changesetNumber;
}


####################################################################
# checkoutCode - Uses the "hg clone" command to checkout code to 
#   the workspace. If the user already has the repository uses the 
#   "hg update" command. Collects data to call functions to set up 
#   the scm change log.
#
# Arguments:
#   - self   the object reference
#   - opts   A reference to the hash with values
#
# Returns:
#   - Output of the the "hg clone" or the "hg update" command.
#
####################################################################
sub checkoutCode
{
    my ($self, $opts) = @_;
    my $here = getcwd();

    if (! (defined $opts->{dest})) {
        warn "dest argument required in checkoutCode";
        return;
    }
    if (! (defined $opts->{depot})) {
        warn "repository argument required in checkoutCode";
        return;
    }
    
    #Change working directory.
    if (defined ($opts->{dest}) && ($opts->{dest} ne "." && $opts->{dest} ne "" )) {
        $opts->{dest} = File::Spec->rel2abs($opts->{dest});
        print "Changing to directory $opts->{dest}\n";
        mkpath($opts->{dest});
        if (!chdir $opts->{dest}) {
            print "could not change to directory $opts->{dest}\n";
            exit 1;
        }
    }
    
    my $command = qq|hg clone "$opts->{depot}" "$opts->{dest}" |;
    $command .= qq|--rev $opts->{MercurialRevision}| if ($opts->{MercurialRevision});

    # command to check for changes from the central repo where we originally created the clone from.
    my $hgIncoming = qq|hg incoming $opts->{depot}|;
    
    
    my $result = $self->RunCommand($command, {LogCommand=>1, LogResult=>1, IgnoreError=>1});
    my $hgIncomingRes = $self->RunCommand($hgIncoming, {LogCommand=>1, LogResult=>1, IgnoreError=>1});
    
    # Check if there was an error on the response.
    # following check is required that changes have been made to the central repo that should be integrated into the local repo.
    if($hgIncomingRes =~ /changeset:   ([\d]+\:[\w\/]+)/) {
        # If so, update the code instead of cloning it.
        # Before running this command, be sure that you are in the root folder of the repo.
        my $pull = qq|hg pull -u "$opts->{depot}" |; # command will pull across change, and submit them to local repo.
        $result = $self->RunCommand($pull, {LogCommand=>1, LogResult=>1});
    } else {
        $result = "Files are already updated";
    }
    
    $command = "hg log -l 1 -b .";
    my $result = $self->RunCommand($command, {LogCommand=>0});
    $result =~ m/changeset:\s+\d+:(.*)\n.*\nuser:\s+(.*)\ndate:\s+(.*)\nsummary:\s+(.*)/;
    
    my $snapshot = $1;
    my $changelog = join("\n","Author: $2","summary: $4", "date: $3");
    
    my $scmKey = $self->getKeyFromUrl($opts->{depot});
    $self->setPropertiesOnJob($scmKey, $snapshot, $changelog);
    
    my ($projectName, $scheduleName, $procedureName) = $self->GetProjectAndScheduleNames();
    
    if ($scheduleName ne ""){
        my $prop = "/projects[$projectName]/schedules[$scheduleName]/ecscm_changelogs/$scmKey";					
        $ec->setProperty($prop, $changelog);
    }
    
    chdir $here;

    return $result;
}
####################################################################
# getKeyFromUrl - Creates a key from the URL 
#
# Arguments:
#   - url   the Mercurial url
#
# Returns:
#   - "Mercurial" prepended to the url with all / replaced by __slash__
####################################################################
sub getKeyFromUrl
{
    my ($self, $url) = @_;
    $url =~ s/\//__slash__/g;
    return "Mercurial-$url";
}

#-------------------------------------------------------------------------
#
#  Find the name of the Project of the current job and the
#  Schedule that was used to launch it
#
#  Params
#       None
#
#  Returns
#       projectName  - the Project name of the running job
#       scheduleName - the Schedule name of the running job
#
#  Notes
#       scheduleName will be an empty string if the current job was not
#       launched from a Schedule
#
#-------------------------------------------------------------------------
sub GetProjectAndScheduleNames
{
    my $self = shift;
	
	my $gCachedScheduleName = "";
    my $gCachedProjectName = "";
    my $gCachedProcedureName = "";
    
	if ($gCachedScheduleName eq "") {

        # Call Commander to get info about the current job
        my ($success, $xPath) = $self->InvokeCommander({SuppressLog=>1}, 
                "getJobInfo", $ENV{COMMANDER_JOBID});

        # Find the schedule name in the properties
        $gCachedScheduleName = $xPath->findvalue('//scheduleName');
        $gCachedProjectName = $xPath->findvalue('//projectName');
        $gCachedProcedureName = $xPath->findvalue('//procedureName');
    }

    return ($gCachedProjectName, $gCachedScheduleName, $gCachedProcedureName);
}

####################################################################
# agent preflight functions
####################################################################

####################################################################
# apf_getScmInfo - If the client script passed some SCM-specific 
#    information, then it is collected here.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
####################################################################
sub apf_getScmInfo
{
    my ($self,$opts) = @_;
        
    my $scmInfo = $self->pf_readFile("ecpreflight_data/scmInfo");
    my @data = split(/\s+/, $scmInfo);
    $opts->{depot} = $data[0];
    $opts->{MercurialRevision} = $data[1];

    print("Mercurial information received from client:\n"
            . "Mercurial URL: $opts->{depot}\n"
            . "Revision: $opts->{MercurialRevision}\n\n");
}

####################################################################
# apf_createSnapshot - Create the basic source snapshot before 
#    overlaying the deltas passed from the client.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
####################################################################

sub apf_createSnapshot
{
    my ($self,$opts) = @_;
    $self->checkoutCode($opts);
}

####################################################################
# driver - Main program for the application.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
####################################################################
sub apf_driver()
{
    my ($self,$opts) = @_;
    
    if ($opts->{test}) { $self->setTestMode(1); }
        $opts->{delta} = 'ecpreflight_files';

    $self->apf_downloadFiles($opts);
    $self->apf_transmitTargetInfo($opts);
    $self->apf_getScmInfo($opts);
    $self->apf_createSnapshot($opts);

    $self->apf_deleteFiles($opts);
    $self->apf_overlayDeltas($opts);
}


####################################################################
# client preflight file
####################################################################

####################################################################
# cpf_hg - Runs a hg command.  Also used for testing, where the 
#       requests and responses may be pre-arranged.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
####################################################################
sub cpf_hg {
    my ($self,$opts, $command, $options) = @_;

    $self->cpf_debug("Running Mercurial command \"$command\"");
    if ($opts->{opt_Testing}) {
        my $request = uc("hg_$command");
        $request =~ s/[^\w]//g;
        if (defined($ENV{$request})) {
            return $ENV{$request};
        } else {
            $self->cpf_error("Pre-arranged command output not found in ENV");
        }
    } else {
        return $self->RunCommand("hg $command", $options);
    }
}

####################################################################
# copyDeltas - Finds all new and modified files, and calls 
#       putFiles to upload them to the server.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
####################################################################
sub cpf_copyDeltas()
{
    my ($self,$opts) = @_;
    $self->cpf_display('Collecting delta information');

    $self->cpf_saveScmInfo($opts,$opts->{scm_url} ."\n"
            . $opts->{scm_lastchange} ."\n"); 

    $self->cpf_findTargetDirectory($opts);
    $self->cpf_createManifestFiles($opts);

    # Collect a list of opened files.

    my $path = $opts->{scm_path};
    my $status = $self->cpf_hg($opts,"status --modified --added --removed --deleted --cwd " . $path);
    my $numFiles = 0;

    my $openedFiles = '';
        
    my @lines = split(/\n/, $status);
    foreach my $line (@lines) {
    	my $type = substr($line, 0, 1);
    
    	if($type =~ /(M|A)/){
    		my $file = substr($line, 2);
    		my $source = $opts->{scm_url} . $file;
            my $dest = $file;
            
            $openedFiles .= $file;
        		
    		$self->cpf_addDelta($opts,$source, $dest);
    		
    		$numFiles += 1;
    	} elsif($type =~ /(R)/){
    		my $file = substr($line, 2);
    		my $dest = $file;
    		
    		$openedFiles .= $file;
    		$self->cpf_addDelete($dest);
    		
    		$numFiles += 1;
    	}
    }
    
    $opts->{rt_openedFiles} = $openedFiles;

    # If there aren't any modifications, warn the user, and turn off auto-
    # commit if it was turned on.

    if ($numFiles == 0) {
        my $warning = 'No files are currently open';
        if ($opts->{scm_autoCommit}) {
            $warning .= '.  Auto-commit has been turned off for this build';
            $opts->{scm_autoCommit} = 0;
        }
        $self->cpf_error($warning);
    } else {
        $self->cpf_closeManifestFiles($opts);
        $self->cpf_uploadFiles($opts);
    }
}

#######################################################################################
# autoCommit - Automatically commit changes in the user's client.  Error out if:
#       - A check-in has occurred since the preflight was started, and the
#         policy is set to die on any check-in.
#       - A check-in has occurred and opened files are out of sync with the
#         head of the branch.
#       - A check-in has occurred and non-opened files are out of sync with
#         the head of the branch, and the policy is set to die on any changes
#         within the client workspace.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
######################################################################################
sub cpf_autoCommit()
{
    my ($self, $opts) = @_;
    # Make sure none of the files have been touched since the build started.

    $self->cpf_checkTimestamps($opts);
    
    # Load userName and password from the credential
    ($opts->{mercurialUserName}, $opts->{mercurialPassword}) = 
        $self->retrieveUserCredential($opts->{credential}, 
        $opts->{mercurialUserName}, $opts->{mercurialPassword});

    # Find the latest revision number and compare it to the previously stored
    # revision number.  If they are the same, then proceed.  Otherwise, do some
    # more advanced checks for conflicts.

    my $out = $self->cpf_hg($opts,"heads --cwd " . $opts->{scm_path});
    $out =~ /changeset:   ([\d]+)/;
    my $latestChange = $1;
    $self->cpf_debug("Latest revision: $latestChange");

    # If the changelists are different, then check the policies.  If it is
    # set to always die on new check-ins, then error out.

    if ($latestChange ne $opts->{scm_lastchange}) {
        $self->cpf_error('A check-in has been made since ecpreflight was started. '
                . 'Sync and resolve conflicts, then retry the preflight '
                . 'build');
    }

    # If there are any updates that overlap with the opened files, then
    # always error out.
    my $path = $opts->{scm_path};
    my $status = $self->cpf_hg($opts,"status --modified --added --removed --deleted --cwd " . $path);
    my $openedFiles = "";
    my @lines = split(/\n/, $status);
    foreach my $line (@lines) {
    	my $type = substr($line, 0, 1);
    
    	if($type =~ /(M|A|R)/){
    		my $file = substr($line, 2);
            $openedFiles .= $file;
    	}
    }

    # If any file have been added or removed, error out.

    if ($openedFiles ne $opts->{rt_openedFiles}) {
        $self->cpf_error("Files have been added and/or removed from the selected "
                . "changelists since the preflight build was launched");
    }

    # Commit the changes.
    my $command = "commit --cwd " . $opts->{scm_path} . " --noninteractive" . " --message \"" . $opts->{scm_commitComment}."\"";
    $command .= " --user $opts->{scm_user}" if ($opts->{scm_user});

    $self->cpf_display("Committing changes");
    $self->cpf_hg($opts, $command, {LogCommand=>1, LogResult=>1});
    $self->cpf_display("Changes have been successfully submitted");
}

####################################################################
# cpf_driver - Main program for the application.
#
# Arguments:
#   - none
#
# Returns:
#   - none
#
####################################################################
sub cpf_driver
{
    my ($self,$opts) = @_;
    $self->cpf_display("Executing Mercurial actions for ecpreflight");

    $::gHelpMessage .= "
Mercurial Options:
  --hgpath <path>       The path to the locally accessible source directory
                        in which changes have been made.  This is generally
                        the path to the root of the workspace.
";

    my %ScmOptions = ( 
        "hgpath=s"             => \$opts->{scm_path},
    );

    Getopt::Long::Configure("default");
    if (!GetOptions(%ScmOptions)) {
        error($::gHelpMessage);
    }    

    if ($::gHelp eq "1") {
        $self->cpf_display($::gHelpMessage);
        return;
    }

    $self->extractOption($opts,"scm_path", { required => 1, cltOption => "hgpath" });

    # If the preflight is set to auto-commit, require a commit comment.
    if ($opts->{scm_autoCommit} &&
            (!defined($opts->{scm_commitComment})|| $opts->{scm_commitComment} eq "")) {
        $self->cpf_error("Required element \"scm/commitComment\" is empty or absent in "
                . "the provided options.  May also be passed on the command "
                . "line using --commitComment");
    }

    # Store the latest checked-in changelist number.

    my $out = $self->cpf_hg($opts,"heads --cwd " . $opts->{scm_path});
    $out =~ /changeset:   ([\d]+)/;
    $opts->{scm_lastchange} = $1;
    $opts->{scm_url} = $opts->{scm_path} . '/';
    
    $self->cpf_debug("Extracted path: ".$opts->{scm_path});
    $self->cpf_debug("Latest revision: ".$opts->{scm_lastchange});
    $self->cpf_debug("URL: ".$opts->{scm_url});

    # Copy the deltas to a specific location.
    $self->cpf_copyDeltas($opts);

    # Auto commit if the user has chosen to do so.

    if ($opts->{scm_autoCommit}) {
        if (!$opts->{opt_Testing}) {
            $self->cpf_waitForJob($opts);
        }
        $self->cpf_autoCommit($opts);
    }
}


1;
