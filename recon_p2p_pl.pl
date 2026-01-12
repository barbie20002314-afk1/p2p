# p2pRecon.pl

use 5.016;
use warnings;
use strict;

use Carp;
use Data::Dumper;
use DateTime;
use DateTime::Format::Strptime;
use DBI;
use Text::CSV;

use FTFCU::apwxvars;
use FTFCU::P2P;

our $VERSION = 1.07;

say "p2pRecon.pl version is: $VERSION";

say "P2P Recon started at " . DateTime->today( time_zone => 'America/Los_Angeles' );

run();

say "P2P Recon finished at " . DateTime->today( time_zone => 'America/Los_Angeles' );

sub run
{    
    my $apwxArgHash = getApwxArgHash();
    
    say "Opening P2P config file";
    my $fhConfig = openConfigFile();
    
    my %p2pArgs = (
        getApwx     =>  $apwxArgHash,
        getP2pDb    =>  1,
        getDnaDb    =>  1,
        configFile  =>  $fhConfig,
        storeConfig =>  'recon',
        storeApwx   =>  'recon',
        storeDbh    =>  'recon',
        recon       =>  1,        
    );
    
    my $p2pClient = FTFCU::P2P->new( \%p2pArgs );

    $p2pClient->{recon}->{apwx}->{ARGV}->{OUTPUT_FILE_PATH} .= "\\"
        if $p2pClient->{recon}->{apwx}->{ARGV}->{OUTPUT_FILE_PATH} !~ /\\$/;

    say "Initializing FTFCU P2P Recon report";
    
    my $rptFilePath =
        $p2pClient->{recon}->{apwx}->{ARGV}->{OUTPUT_FILE_PATH}
        . "P2P_RECON_"
        . DateTime->now(time_zone => 'America/Los_Angeles')->mdy('-')
        . ".txt";
        
    open my $fhRpt, '>', $rptFilePath
        or die "Could not open P2P Recon Report for output at $rptFilePath";
        
    my $fhReconRpt = $p2pClient->{recon}->initializeReconReport( $fhRpt );
        
    my $p2pCsvFilePath =
        $p2pClient->{recon}->{apwx}->{ARGV}->{OUTPUT_FILE_PATH}
        . "P2P_RECON_UNRECONCILED_P2P_"
        . DateTime->now(time_zone => 'America/Los_Angeles')->mdy('-')
        . ".csv";
        
    open my $fhP2PCsv, '>', $p2pCsvFilePath
        or die "Could not open P2P CSV Recon Report for output at $p2pCsvFilePath"; 
        
    my @p2pColHeaders = qw(
        SOURCE TRAN_ID CXC_PAYMENT_ID RECONCILED_YN TRAN_TYPE
        TRAN_AMOUNT TRAN_DATETIME ACCTNBR RTXNNBR
        NTWK NTWK_ID RECON_STATUS
    );
    
    my $csvP2P = Text::CSV->new ( { binary => 1 } )
        or warn "Could not write CSV data for unreconciled transactions ".Text::CSV->error_diag ();
                 
    $csvP2P->say( $fhP2PCsv, \@p2pColHeaders );
    
    my $dnaCsvFilePath =
        $p2pClient->{recon}->{apwx}->{ARGV}->{OUTPUT_FILE_PATH}
        . "P2P_RECON_UNRECONCILED_DNA_"
        . DateTime->now(time_zone => 'America/Los_Angeles')->mdy('-')
        . ".csv";
  
    open my $fhDNACsv, '>', $dnaCsvFilePath
        or die "Could not open P2P CSV Recon Report for output at $dnaCsvFilePath";
        
    my @dnaColHeaders = qw(
        SOURCE TRAN_ID CXC_PAYMENT_ID RECONCILED_YN TRAN_SOURCE
        TRAN_DATE TRAN_TYPE TRAN_AMT ACCTNBR CARDNBR RECON_STATUS
    );
    
    my $csvDNA = Text::CSV->new ( { binary => 1 } ) 
        or warn "Could not write CSV data for unreconciled transactions ". Text::CSV->error_diag ();
                 
    $csvDNA->say( $fhDNACsv, \@dnaColHeaders );
        

    $p2pClient->{recon}->{dbh}->{p2p}->{AutoCommit} = 0; # not working for some reason via DBI->connect( { AutoCommit => 1 } )  
    $p2pClient->{recon}->{dbh}->{dna}->{AutoCommit} = 0; # not working for some reason via DBI->connect( { AutoCommit => 1 } )
    
    my $cutoffTimes = getCutoffTimes( $p2pClient->{recon}->{dbh}->{dna}, $p2pClient->{recon}->{apwx}->{ARGV}->{RPT_ONLY}, $p2pClient->{recon}->{apwx}->{ARGV}->{TEST_CUTOFF_DATETIME} );
    
    $p2pClient->{recon}->{reconTranSql} = $p2pClient->{recon}->getReconTranSql( $cutoffTimes );
    $p2pClient->{recon}->{updateTranSql} = $p2pClient->{recon}->getUpdateTranSql();
    
    $p2pClient->{recon}->getInNtwkOrgs();
    
    say "Fetching transactions to reconcile";
    $p2pClient->{recon}->getTransToReconcile();
    
    say "Reconciling...";
    
    foreach my $p2pTranType ( sort keys %{ $p2pClient->{recon}->{transToReconcile}->{p2p} } ){

        next unless $p2pClient->{recon}->{config}->{recon}->{reconTranTypes}->{p2p}->{$p2pTranType}->{getTrans};
        
        my ( $updateReconDateAry, $reconciled, $unreconciled ) = $p2pClient->{recon}->reconcileTrans(
            {
                tranType            =>  $p2pTranType,
                transToReconcile    =>  $p2pClient->{recon}->{transToReconcile},
                inNtwkOrgs          =>  $p2pClient->{recon}->{inNtwkOrgs},
                overrideOO          =>  1,
            }
        );
        
        # Update recon date for all reconciled trans in P2P database (Payment & DetailTransaction tables )
        if ( scalar @{ $updateReconDateAry } ){
            
            my $sqlName =  $p2pClient->{recon}->{reconDispatch}->{$p2pTranType}->{updateReconDateSql};
            my $updateErrors = $p2pClient->{recon}->updateReconDate(
                {
                    tranType            =>  $p2pTranType,
                    updateReconDates    =>  $updateReconDateAry,
                    updateSql           =>  $p2pClient->{recon}->{updateTranSql}->{$sqlName},
                    db                  =>  'p2p',
                    dbh                 =>  $p2pClient->{recon}->{dbh}->{p2p},
                }
            );
            
            if ( $updateErrors ){
                say "Update errors occurred for $p2pTranType - rolling back updates for this tran type"; 
                $p2pClient->{recon}->{dbh}->{p2p}->rollback;
            }
            else{
                $p2pClient->{recon}->{apwx}->{ARGV}->{RPT_ONLY} eq 'N'    
                    ? $p2pClient->{recon}->{dbh}->{p2p}->commit
                    : $p2pClient->{recon}->{dbh}->{p2p}->rollback
            }
        }

        my $rptName = $p2pClient->{recon}->{config}->{recon}->{reconTranTypes}->{p2p}->{$p2pTranType}->{reportName};
        
        $p2pClient->{recon}->printReconReport( $fhReconRpt, 'p2p', $rptName, $reconciled, $unreconciled );
        
        printUnreconciledToCSV( $rptName, $fhP2PCsv, $csvP2P, $unreconciled );
    }
    
    foreach my $dnaTranType ( sort keys %{ $p2pClient->{recon}->{transToReconcile}->{dna} } ){
        
            my ( $updateReconDateAry, $reconciled, $unreconciled ) = $p2pClient->{recon}->reconcileTrans(
                {
                    tranType            =>  $dnaTranType,
                    transToReconcile    =>  $p2pClient->{recon}->{transToReconcile}->{dna}->{$dnaTranType},
                    inNtwkOrgs          =>  $p2pClient->{recon}->{inNtwkOrgs},
                    overrideOO          =>  1,
                }
            );        
        
        # Update recon date for 'dna' transaction records ( i.e. RTXN, GL, OSIUPDATE MC/Visa tables )
        if ( scalar @{ $updateReconDateAry } ){
            
            my $updateErrors = $p2pClient->{recon}->updateReconDate(
                {
                    tranType            =>  $dnaTranType,
                    updateReconDates    =>  $updateReconDateAry,
                    updateSql           =>  $p2pClient->{recon}->{updateTranSql}->{$dnaTranType},
                    db                  =>  'dna',
                    dbh                 =>  $p2pClient->{recon}->{dbh}->{dna},
                }
            );
            
            if ( $updateErrors ){
                say "Update errors occurred for $dnaTranType - rolling back updates for this tran type"; 
                $p2pClient->{recon}->{dbh}->{dna}->rollback;
            }
            else{
                $p2pClient->{recon}->{apwx}->{ARGV}->{RPT_ONLY} eq 'N'    
                    ? $p2pClient->{recon}->{dbh}->{dna}->commit
                    : $p2pClient->{recon}->{dbh}->{dna}->rollback
            }
        }
        
        my $rptName = $p2pClient->{recon}->{config}->{recon}->{reconTranTypes}->{dna}->{$dnaTranType}->{reportName};
        
        $p2pClient->{recon}->printReconReport( $fhReconRpt,'dna', $rptName, $reconciled, $unreconciled );
        
        printUnreconciledToCSV( $rptName, $fhDNACsv, $csvDNA, $unreconciled );
    }

    $fhReconRpt->close;
    $fhP2PCsv->close;
    $fhDNACsv->close;
    
    foreach my $dbh ( keys %{ $p2pClient->{recon}->{dbh} } ){
        
        $p2pClient->{recon}->{apwx}->{ARGV}->{RPT_ONLY} eq 'N'    
            ? $p2pClient->{recon}->{dbh}->{$dbh}->commit
            : $p2pClient->{recon}->{dbh}->{$dbh}->rollback;
            
        $p2pClient->{recon}->{dbh}->{$dbh}->disconnect();
    }
    
    return 1;
}

sub getApwxArgHash
{
        my $outputFilePath = { ( map{ split /=/, $_ }@ARGV ) }->{OUTPUT_FILE_PATH}
        or die "OUTPUT_FILE_PATH ARG is undefined"; 
    
    my %apwxArgHash = (
        ARGV        =>  {
            HOST                        =>  { required => 1, defined => 1, allow => qr/^FTFTST|FTFRPT|FTFDP|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/i,   }, # valid FTFCU hostname or IP address
            SID                         =>  { required => 1, defined => 1, allow => qr/^FTFTST|FTFRPT|FTFDP|\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/i,   },
            P2P_SERVER                  =>  { required => 1, defined => 1,                                                                          },
            P2P_SCHEMA                  =>  { required => 1, defined => 1,                                                                          },
            CONFIG_FILE                 =>  { required => 1, defined => 1, allow => qr/\.yaml|yml$/i                                                }, # a YAML file
            RECON_GL                    =>  { required => 1, defined => 1, allow => qr/^\d+$/                                                       },
            OUTPUT_FILE_PATH            =>  { required => 1, defined => 1, allow => sub { -d $outputFilePath }                                      },
            RPT_ONLY                    =>  { required => 1, defined => 1, allow => qr/^Y|N$/                                                       },
            USE_MAX_CREATED_DATETIME    =>  { required => 1, defined => 1, allow => qr/^Y|N$/                                                       },
        },
        APWX_VARS   =>  {
            'OSIUPDATE'             => { required => 1, defined => 1                                                                                },
            'OSIUPDATE_PW'          => { required => 1, defined => 1                                                                                },         
        },
        ENV                         =>  {
            JOBID                   => { required => 1, defined => 1                                                                                },    
        },
    );
    
    return \%apwxArgHash;
}

sub openConfigFile
{
    my $configFilePath = { ( map{ split /=/, $_ }@ARGV ) }->{CONFIG_FILE}
        or die "CONFIG_FILE ARG is undefined";

    open my $fhConfig, '<', $configFilePath
        or die 'Could not open P2P Recon config file at ' . $configFilePath;
        
    return $fhConfig;
}

sub getCutoffTimes
{
    my ( $dbh, $rptOnly, $tstCutoffDateTime ) = @_;
    

    my $cdatStartDateTime;
    
    if ( $rptOnly eq 'Y'){
        $cdatStartDateTime = $tstCutoffDateTime;    
    }
    else{
        my $sthCdat = $dbh->prepare_cached (
            qq(
                SELECT
                    TO_CHAR( MAX(SO_JOB_STARTED), 'MM-DD-YYYY HH24:MI:SS' ) bumpDateStartDateTime
                FROM APPWORX.SO_JOB_HISTORY
                WHERE SO_MODULE LIKE 'RO_BARUN%'
                AND SO_PARENT_NAME LIKE 'START_PREBATCH'
                AND SO_STATUS_NAME= 'FINISHED'
                ORDER BY SO_START_DATE DESC          
            )
        );
        
        $sthCdat->execute();
        $cdatStartDateTime = $sthCdat->fetchrow_arrayref()->[0];
        $sthCdat->finish;
    }
    
    my ( $cdatDateStr, $cdatTimeStr ) = split /\s/, $cdatStartDateTime;
    my ( $cM, $cD, $cY ) = split /\/|\-/, $cdatDateStr;
    my ( $cH, $cMi, $cS ) = split /:/, $cdatTimeStr;
    
    my $sthGetVrctTime = $dbh->prepare_cached(
        qq(
            SELECT bankoptionvalue
            FROM bankoption
            WHERE bankoptioncd = 'VRCT'        
        )
    );
    
    $sthGetVrctTime->execute();
    my $vrctVarStr = $sthGetVrctTime->fetchrow_arrayref()->[0];
    $sthGetVrctTime->finish;
    
    my ( $vH, $vMi, $vS ) = split /:/, $vrctVarStr;
    
    my $dtCdat = DateTime->new(
        time_zone   =>  'America/Los_Angeles',
        year       => $cY,
        month      => $cM,
        day        => $cD,
        hour       => $cH,
        minute     => $cMi,
        second     => $cS,        
    );
    
    my $dtVrct = DateTime->new(
        time_zone   =>  'America/Los_Angeles',
        year       => $cY,
        month      => $cM,
        day        => $cD,
        hour       => $vH,
        minute     => $vMi,
        second     => $vS,        
    );
    
    my $dtCompResult = DateTime->compare( $dtCdat, $dtVrct );
    
    my $maxCreateDate = (
        $dtCompResult == -1
            ? $cdatStartDateTime # bumpdate start time is earlier, use bump-date datetime
            :
                $cM . '/' # VRCT time is earlier, use bump-date m/d/y + VRCT timestamp
                . $cD . '/'
                . $cY . ' '
                . $vrctVarStr
    );
    
    my $mcd = substr $maxCreateDate, 0, 10;
    my @mcdAry = split /\/|-/, substr($maxCreateDate,0,10);
    my $mcdPlus1 = DateTime->new(
        month   =>  $mcdAry[0],
        day     =>  $mcdAry[1],
        year    =>  $mcdAry[2],
    )->add(days => 1)->mdy('/');
    
    my %cutoffTimes = (
        DNA         =>  $maxCreateDate,
        PAYMENT     =>  $maxCreateDate,
        DETAIL_RECORD   =>{
            MONEYSEND   =>  "$mcd 23:00:00",
            MASTERCARD  =>  "$mcd 13:45:00",
            MAESTRO     =>  "$mcd 23:00:00",
            VISA        =>  "$mcdPlus1 03:00:00",            
        },
    );
    
    return \%cutoffTimes;
}

sub printUnreconciledToCSV
{
    my ( $rptName, $fhCsv, $csv, $unreconciledTrans ) = @_;
    
    # print unreconciled to a csv file so accounting can sort by date
    foreach ( @{ $unreconciledTrans } ){
        my @unreconciledTranAry = @{ $_ };
        unshift @unreconciledTranAry, $rptName;
        $csv->say( $fhCsv, \@unreconciledTranAry );     
    };
    
    return 1;
}

exit 0;