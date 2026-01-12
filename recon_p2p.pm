Here is the pm file: let me know at highlevel in 5 lines.


package FTFCU::P2P::Recon;

use 5.016;
use warnings;
use strict;

use Carp;
use DateTime;
use DBI;
use Text::CSV;
use YAML qw(LoadFile);

use FTFCU::apwxvars;

our $VERSION = 1.08;

sub new
{
    my ( $class, $args ) = @_;
    
    my $self = bless {}, $class;
    
    $self->{fileLoader} = FTFCU::P2P::Recon::FileLoader->new( $args )
        if $args->{fileLoader};    
    
    $self->{reconDispatch} = {
        zelleToACH  =>  {
            recon               =>  \&_reconZelleAch,
            updateReconDateSql  =>  'detailRecord',
        },
        zelleNonACH     =>  {
            recon               =>  \&_reconZelleNonAch,
            updateReconDateSql  =>  'detailRecord',
        },
        ftAppToCard     =>  {
            recon               =>  \&_reconFtAppToCard,
            updateReconDateSql  =>  'payment',
        },
        ftAppToDDA      =>  {
            recon               =>  \&_reconFtAppToDDA,
            updateReconDateSql  =>  'payment',
        },
        oonDDAToFtApp   =>  {
            recon               =>  \&_reconOONDDAToFtApp,
            updateReconDateSql  =>  'payment',
        },
        oonCardToFtApp  =>  {
            recon               =>  \&_reconOONCardToFtApp,
            updateReconDateSql  =>  'payment',
        },
        inNtwkToFtApp   =>  {
            recon               =>  \&_reconInNtwkToFtApp,
            updateReconDateSql  =>  'payment',
        },
        dnaRecon        =>  {
            recon               =>  \&_reconDnaTrans,    
        },
        dnaReconGL      =>  {
            recon               =>  \&_reconDnaGlTrans,    
        },
        mc_zeldly       =>  {
            recon               =>  \&_reconMcZelDly,            
        },
        visa_rw3        =>  {
            recon               =>  \&_reconVisaRw3,    
        },   
    };
        
    return $self;
}

sub getInNtwkOrgs
{
    my ( $self ) = @_;
    
    my $sth = $self->{dbh}->{p2p}->prepare_cached(
        qq(
            SELECT 
                OrgId,
                OrgName
            FROM Organization        
        )
    );
    
    $sth->execute();
    
    $self->{inNtwkOrgs} = $sth->fetchall_hashref( 'OrgId' );
    
    $sth->finish;
    
    return 1;
}

sub getTransToReconcile
{
    my ( $self, $args ) = @_; # , $maxCreatedDateTime
    
    my $tranTypes = $self->{config}->{recon}->{reconTranTypes}
        if ! $args->{tranTypes};

    croak "P2P database handle is undefined or not a DBI database handle"
        if ! $self->{dbh} || grep{ ref $self->{dbh}->{$_} ne 'DBI::db' }( keys %{ $self->{dbh} } );
        
    my $transToReconcile = {};
        
    foreach my $db ( keys %{ $tranTypes } ){
        
        foreach my $tTyp ( keys %{ $tranTypes->{$db} } ){
            
            next if ! $tranTypes->{$db}->{$tTyp}->{getTrans};
            
            my @sqlArgs = map{
                $self->{apwx}->{ARGV}->{$_}
                    ? $self->{apwx}->{ARGV}->{$_}
                    : ()
            } @{ $tranTypes->{$db}->{$tTyp}->{sqlArgs} } if $tranTypes->{$db}->{$tTyp}->{sqlArgs};
            
            my $sth = $self->{dbh}->{$db}->prepare_cached( $self->{reconTranSql}->{$db}->{$tTyp} )
                or die $self->{dbh}->{$db}->errstr;
            
            if ( scalar @sqlArgs ){
                $sth->execute( @sqlArgs ) or die $sth->errstr;    
            }
            else{
                $sth->execute() or die $sth->errstr;                
            }

            if ( $tranTypes->{$db}->{$tTyp}->{sqlKeyCols} ){
                my @sqlKeyCols = @{ $tranTypes->{$db}->{$tTyp}->{sqlKeyCols} };
                $transToReconcile->{$db}->{$tTyp} = $sth->fetchall_hashref( \@sqlKeyCols );
                $sth->finish;
            }
            else{
                $transToReconcile->{$db}->{$tTyp} = $sth->fetchall_arrayref( {} );
                $sth->finish;
            }
            
        }
    }
        
    $self->{transToReconcile} = $transToReconcile;
    
    return 1;
}

sub reconcileTrans
{
    my ( $self, $args ) = @_;
    
    my $tranType = $args->{tranType};
    
    my ( $updateReconDateAry, $reconciledTranAry, $unreconciledTranAry ) = $self->{reconDispatch}->{ $tranType }->{recon}( $args );
    
    return ( $updateReconDateAry, $reconciledTranAry, $unreconciledTranAry )
        if $args->{overrideOO} || ! ref $self eq 'FTFCU::P2P::Recon';
        
    $self->{reconciledTrans}->{$tranType} = $reconciledTranAry
        if scalar @{ $reconciledTranAry };
    $self->{unreconciledTrans}->{$tranType} = $unreconciledTranAry
        if scalar @{ $unreconciledTranAry };
    $self->{updateReconDate}->{$tranType} = $updateReconDateAry
        if scalar @{ $updateReconDateAry };
    
    return 1;
}

sub initializeReconReport
{
    my ( $self, $fhRpt ) = @_;
        
    say $fhRpt '-' x 300;
    say $fhRpt 'FTFCU P2P RECON';
    say $fhRpt '-' x 300;
    say $fhRpt 'RUN DATE: ' . DateTime->now( time_zone => 'America/Los_Angeles' );
    say $fhRpt 'P2P DATABASE: ' . $self->{apwx}->{ARGV}->{P2P_SERVER};
    say $fhRpt 'DNA DATABASE: ' . uc( $self->{apwx}->{ARGV}->{HOST} );
    say $fhRpt 'REPORT ONLY: ' . uc( $self->{apwx}->{ARGV}->{RPT_ONLY} );
    say $fhRpt '-' x 300;
    print $fhRpt "\n\n";
    
    return $fhRpt;
}

sub printReconReport
{
    my ( $self, $fhRpt, $db, $rptName, $reconciledTrans, $unreconciledTrans ) = @_;
    
    my ( @colHeaders, $headerFormat, $format );
    
    my @sortedReconciledTrans = (
        $db eq 'p2p'
            ? sort{ $b->[5] cmp $a->[5] } @{ $reconciledTrans } # P2P TRAN_DATE
            : sort{ $b->[4] cmp $a->[4] } @{ $reconciledTrans } # DNA TRAN_DATE
    );
    
    my @sortedUnreconciledTrans = (
        $db eq 'p2p'
            ? sort{ $b->[5] cmp $a->[5] } @{ $unreconciledTrans } # P2P TRAN_DATE
            : sort{ $b->[4] cmp $a->[4] } @{ $unreconciledTrans } # DNA TRAN_DATE 
    );
    
    if ( $db eq 'p2p' ){
        $headerFormat =
            "%-15s%-20s%-15s%-20s%-20s%-25s%-25s%-20s%-15s%-50s%-75s";
        $format =
            "%-15s%-20s%-15s%-20s%-20s%-25s%-25s%-20s%-15s%-50s%-75s";
    
        @colHeaders = qw(
            TRAN_ID CXC_PAYMENT_ID RECONCILED_YN TRAN_TYPE
            TRAN_AMOUNT TRAN_DATE ACCTNBR RTXNNBR NTWK
            NTWK_ID RECON_STATUS
        );
        
        #@colHeaders = qw(
        #    TRAN_ID CXC_PAYMENT_ID RECONCILED_YN TRAN_TYPE
        #    TRAN_AMOUNT CREATED_DATETIME ACCTNBR RTXNNBR
        #    NTWK NTWK_ID RECON_STATUS
        #); 
    }
    elsif( $db eq 'dna' ){
        $headerFormat =
            "%-50s%-20s%-15s%-15s%-25s%-15s%-20s%-25s%-20s%-95s";
        $format =
            "%-50s%-20s%-15s%-15s%-25s%-15s%-20s%-25s%-20s%-95s";

        @colHeaders = qw(
            TRAN_ID CXC_PAYMENT_ID RECONCILED_YN TRAN_SOURCE
            TRAN_DATE TRAN_TYPE TRAN_AMT ACCTNBR CARDNBR RECON_STATUS
        );
    }

    say $fhRpt $rptName;
    say $fhRpt '-' x 300;
    
    my $header = sprintf $headerFormat, @colHeaders;
    say $fhRpt $header;
    say $fhRpt '-' x 300;
    
    foreach my $rt ( @{ $reconciledTrans } ){
        my $line = sprintf $format, @{ $rt };
        say $fhRpt $line;
    }
    
    foreach my $urt ( @{ $unreconciledTrans } ){
        my $line = sprintf $format, @{ $urt };
        say $fhRpt $line;        
    }
    
    say $fhRpt '-' x 300;
    print $fhRpt "\n";
    
    my $numReconciled = sprintf "%15s", ( scalar @sortedReconciledTrans // 0 ) ; # @{ $reconciledTrans }
    my $numUnreconciled = sprintf "%15s",( scalar  @sortedUnreconciledTrans // 0 ); # @{ $unreconciledTrans }
    my $crAmtReconciled = 0;
    my $drAmtReconciled = 0;
    my $crAmtUnreconciled = 0;
    my $drAmtUnreconciled = 0;

    # increment Cr/Dr reconciled amount totals    
    if ( $db eq 'p2p' ){
        map{
            $crAmtReconciled += (
                $_->[3] eq 'CREDIT' # tran code
                    ? $_->[4] # tran amount 
                    : 0
            )
        }@{ $reconciledTrans };
        
        map{
            $drAmtReconciled += (
                $_->[3] eq 'DEBIT'
                    ? $_->[4]
                    : 0
            )
        }@{ $reconciledTrans };
        
        map{
            $crAmtUnreconciled += (
                $_->[3] eq 'CREDIT'
                    ? $_->[4]
                    : 0
            )
        }@{ $unreconciledTrans };
        
        map{
            $drAmtUnreconciled += (
                $_->[3] eq 'DEBIT'
                    ? $_->[4]
                    : 0
            )
        }@{ $unreconciledTrans };
    }
    elsif( $db eq 'dna' ){
        map{
            $crAmtReconciled += (
                $_->[5] eq 'CREDIT' # tran code
                    ? $_->[6] # tran amount
                    : 0
            )
        }@{ $reconciledTrans };
        
        map{
            $drAmtReconciled += (
                $_->[5] eq 'DEBIT'
                    ? $_->[6]
                    : 0
            )
        }@{ $reconciledTrans };
        
        map{
            $crAmtUnreconciled += (
                $_->[5] eq 'CREDIT'
                    ? $_->[6]
                    : 0
            )
        }@{ $unreconciledTrans };
        
        map{
            $drAmtUnreconciled += (
                $_->[5] eq 'DEBIT'
                    ? $_->[6]
                    : 0
            )
        }@{ $unreconciledTrans };    
    }
    
    say $fhRpt "$rptName Reconciliation Totals";
    say $fhRpt '-' x 50;
    print $fhRpt "\n";
    say $fhRpt 'Reconciled:';
    say $fhRpt '-' x 50;
    say $fhRpt sprintf "%-35s%15s", "Number of Transactions:", $numReconciled;
    say $fhRpt sprintf "%-35s%15s", "Credit Amount:", $crAmtReconciled;
    say $fhRpt sprintf "%-35s%15s", "Debit Amount:", $drAmtReconciled;
    print $fhRpt "\n";
    say $fhRpt 'Unreconciled:';
    say $fhRpt '-' x 50;
    say $fhRpt sprintf "%-35s%15s", "Number of Transactions:", $numUnreconciled;
    say $fhRpt sprintf "%-35s%15s", "Credit Amount:", $crAmtUnreconciled;
    say $fhRpt sprintf "%-35s%15s", "Debits Amount:", $drAmtUnreconciled;
    
    say $fhRpt '-' x 300;
    print $fhRpt "\n\n";
    
    return 1;
}

sub updateReconDate
{
    my ( $self, $args ) = @_;
    
    my $tranType = $args->{tranType};
    
    say "Updating Recon Date for " . $tranType;
    
    my $dbh = $args->{dbh};
    my $sql = $args->{updateSql};
    my @updateAry = @{ $args->{updateReconDates} };
    
    my $sth = $dbh->prepare_cached( $sql );
    
    my @updateStatAry;
    
    $sth->execute_for_fetch( sub{ shift @updateAry }, \@updateStatAry );
    
    $sth->finish;

    my @notUpdated;
    
    if ( $args->{db} eq 'p2p' ){
        @notUpdated = map{
            $updateStatAry[$_] != 1 # SQL Server returns 1 on success
                ? $args->{updateAry}->[$_]
                : ()
        } keys @updateStatAry;        
    }
    elsif ( $args->{db} eq 'dna' ){
        @notUpdated = map{
            $updateStatAry[$_] != -1 # Oracle returns -1 on success
                ? $args->{updateAry}->[$_]
                : ()
        } keys @updateStatAry;           
    }
    
    scalar @notUpdated
        ? return \@notUpdated
        : return;
}

sub getReconTranSql
{   
    my ( $self, $createdDateTime ) = @_;
    
    my $with = qq(
        WITH td
        AS (
            SELECT 
                p.Id,
                CASE
                    WHEN p.ModifiedDate IS NOT NULL
                    THEN p.ModifiedDate
                    ELSE p.CreatedDate
                END TranDate
            FROM Payment p
        )        
    );
    # ftAppToCard ftAppToDDA inNtwkToFtApp oonCardToFtApp oonDDAToFtApp
    my $sql = {
        p2p     =>  {
            inNtwkToFtApp   =>  qq(
                $with                
                SELECT
                    p.Id,
                    p.CXCPaymentID,
                    p.Amount,
                    p.SenderOrgId,
                    p.SenderAccountNo,
                    c.DefaultAccountNo,
                    p.RecipientOrgId,
                    p.EffectiveDate,
                    p.[Status],
                    p.TransactionType,
                    p.CreatedDate,
                    p.ACHProcessStatus,
                    c.DefaultAccountNo,
                    td.TranDate
                FROM Payment p
                JOIN td ON p.id = td.id
                JOIN Customer c
                    ON p.CustomerId = c.Id
                WHERE p.ReconcileDate IS NULL
                AND p.SenderOrgId != 'ONS'
                AND p.TransactionType = 'CREDIT'
                AND p.RecipientOrgId = 'FTF'
                AND NOT EXISTS(
                        SELECT 1
                        FROM DetailRecord d
                        WHERE p.CXCPaymentId = d.PaymentCXCPaymentId
                )
                AND UPPER(p.Status) IN('SENT','DELIVERED')
            ),
            oonCardToFtApp      =>  qq(
                $with 
                SELECT
                    p.Id,
                    p.CXCPaymentID,
                    p.Amount,
                    p.SenderOrgId,
                    p.SenderAccountNo,
                    c.DefaultAccountNo,
                    p.RecipientOrgId,
                    p.EffectiveDate,
                    p.[Status],
                    p.TransactionType,
                    p.CreatedDate,
                    p.ACHProcessStatus,
                    c.DefaultAccountNo,
                    td.TranDate
                 FROM Payment p
                 JOIN td ON p.id = td.id
                 LEFT JOIN Customer c
                     ON p.CustomerId = c.Id
                 WHERE p.ReconcileDate IS NULL
                 AND p.SenderOrgId IN('MSC','VSA')
                 AND p.RecipientOrgId = 'FTF'
                 AND UPPER(p.Status) IN('SENT','DELIVERED')
                 AND EXISTS(
                     SELECT 1
                     FROM DetailRecord d
                     WHERE p.CXCPaymentId = d.PaymentCXCPaymentId
                 )
            ),
            oonDDAToFtApp       =>  qq(
                $with                
                SELECT
                    p.Id,
                    p.CXCPaymentID,
                    p.Amount,
                    p.SenderOrgId,
                    p.SenderAccountNo,
                    c.DefaultAccountNo,
                    p.RecipientOrgId,
                    p.EffectiveDate,
                    p.[Status],
                    p.TransactionType,
                    p.CreatedDate,
                    p.ACHProcessStatus,
                    c.DefaultAccountNo,
                    td.TranDate
                FROM Payment p
                JOIN td ON p.id = td.id
                LEFT JOIN Customer c
                    ON p.CustomerId = c.Id
                WHERE p.ReconcileDate IS NULL
                AND p.SenderOrgId = 'ONS'
                AND p.RecipientOrgId = 'FTF'
                AND UPPER(p.Status) IN ('SENT','DELIVERED')
            ),
            ftAppToCard         =>  qq(
                $with                
                SELECT
                    p.Id,
                    p.CXCPaymentID,
                    p.Amount,
                    p.SenderOrgId,
                    p.SenderAccountNo,
                    c.DefaultAccountNo,
                    p.RecipientOrgId,
                    p.EffectiveDate,
                    p.[Status],
                    p.TransactionType,
                    p.CreatedDate,
                    p.ACHProcessStatus,
                    c.DefaultAccountNo,
                    td.TranDate
                FROM Payment p
                JOIN td ON p.id = td.id
                LEFT JOIN Customer c
                    ON p.CustomerId = c.Id
                WHERE p.ReconcileDate IS NULL
                AND p.SenderOrgId = 'FTF'
                AND p.RecipientOrgId IN('MSC','VSA')
                AND p.ReconcileDate IS NULL
                AND UPPER(p.Status) IN('SENT','DELIVERED') 
            ),
            ftAppToDDA          =>  qq(
                $with
                SELECT
                    p.Id,
                    p.CXCPaymentID,
                    p.Amount,
                    p.SenderOrgId,
                    p.SenderAccountNo,
                    c.DefaultAccountNo,
                    p.RecipientOrgId,
                    p.EffectiveDate,
                    p.[Status],
                    p.TransactionType,
                    p.CreatedDate,
                    p.ACHProcessStatus,
                    c.DefaultAccountNo,
                    td.TranDate
                FROM Payment p
                JOIN td ON p.id = td.id
                LEFT JOIN Customer c
                    ON p.CustomerId = c.Id               
                WHERE p.ReconcileDate IS NULL
                AND p.SenderOrgId = 'FTF'
                AND p.RecipientOrgId NOT IN('MSC','VSA')
                AND p.TransactionType = 'DEBIT'
                AND UPPER(p.Status) IN('SENT','DELIVERED')
            ),
            zelleToACH          =>  qq(
                    SELECT *
                    FROM DetailRecord d
                    WHERE d.ReconcileDate IS NULL
                    AND SenderOrgId = 'MSC'
                    AND d.PaymentTransferToReceivingFI = 1 
                    AND UPPER(SenderBankName) = 'FIRST TECH'
            ),
            zelleNonACH         => qq(
                    SELECT
                        Id,
                        PaymentAmount,
                        PaymentCXCPaymentId,
                        PaymentTransferToReceivingFI,
                        SenderOrgId,
                        RecipientOrgId,
                        DebitNetworkId,
                        DebitNetworkTransactionType,
                        DebitNetworkTransactionId,
                        CreatedDate,
                        Source,
                        EffectiveDate
                    FROM DetailRecord d
                    WHERE d.ReconcileDate IS NULL
                    AND SenderOrgId IN('MSC','VSA','FTF')
                    AND d.PaymentTransferToReceivingFI = 0
            ),
        },
        dna     =>  {
            mc_zeldly           =>  qq(
                SELECT
                    TO_CHAR(FILE_DATE,'MM/DD/YYYY') FILE_DATE,
                    P2P_TRAN_ID,
                    RECORD_TYPE,
                    PARTNER_ID,
                    PARTNER_NAME,
                    REFERENCE_ID,
                    TRANSACTION_TYPE,
                    PAYMENT_TYPE,
                    TO_CHAR(DATETIME_CREATED,'MM/DD/YYYY HH24:MI:SS') DATETIME_CREATED,
                    TO_CHAR(DATETIME_PROCESSED,'MM-DD-YYYY HH24:MI:SS') DATETIME_PROCESSED,
                    SOURCE,
                    DESTINATION,
                    SETTLED_BY,
                    ACCOUNT_NUMBER,
                    TRANSACTION_AMOUNT,
                    TRANSACTION_CURRENCY,
                    INTERCHANGE_AMOUNT,
                    RATE_TYPE_INDICATOR,
                    ERROR,
                    RESPONSE_CODE,
                    NETWORK_RESPONSE_CODE,
                    CUTOFF_DATE,
                    SENDER_FIRST_NAME,
                    SENDER_LAST_NAME,
                    RECEIVER_FIRST_NAME,
                    RECEIVER_LAST_NAME,
                    PAYMENT_ORIGINATION_COUNTRY,
                    INSTITUTION_COUNTRY,
                    SYSTEM_TRACE_AUDIT_NUMBER,
                    RETRIEVAL_REFERENCE,
                    FUNDING_SOURCE,
                    STATEMENT_DESCRIPTOR,
                    CARD_ACCEPTOR_ID,
                    MERCHANT_CATEGORY_CODE,
                    PROCESSING_CODE,
                    SWITCH_SERIAL_NUMBER,
                    RESERVED01,
                    RESERVED02,
                    RESERVED03,
                    RESERVED04,
                    RESERVED05,
                    RESERVED06,
                    RESERVED07,
                    RESERVED08,
                    RESERVED09,
                    RESERVED11,
                    RESERVED12,
                    RESERVED13,
                    RESERVED14,
                    RESERVED15,
                    RECON_DATE
                FROM osiupdate.p2p_recon_mc_zeldly
                WHERE recon_date IS NULL
            ),
            visa_rw3            =>  qq(
                SELECT
                    TO_CHAR(FILE_DATE,'MM/DD/YYYY') FILE_DATE,
                    TRAN_ID,
                    TRACE_NUMBER,
                    RETRIEVAL_REFERENCE_NUMBER,
                    RESPONSE_CODE,
                    TRAN_AMOUNT,
                    TRAN_CODE,
                    CARD_NUMBER,
                    LOCAL_DATE,
                    LOCAL_TIME,
                    TRAN_DATE,
                    TRAN_TIME,
                    RECON_DATE
                FROM osiupdate.p2p_recon_visa_rw3
                WHERE recon_date IS NULL
            ),
            dnaRecon            =>  qq(
                SELECT
                    rea.acctnbr,
                    rea.rtxnnbr,
                    rea.rtxnentityattribvalue cxcpmtid,
                    TRUNC(rea.datelastmaint) entityattribdate,
                    TO_CHAR(r.origpostdate,'MM/DD/YYYY HH24:MI:SS' ) origpostdate,
                    r.tranamt,
                    r.rtxntypcd,
                    r.currrtxnstatcd,
                    r.reversalrtxnnbr,
                    a.mjaccttypcd,
                    a.currmiaccttypcd
                FROM rtxnentityattrib rea
                JOIN rtxn r
                    ON rea.rtxnnbr = r.rtxnnbr AND rea.acctnbr = r.acctnbr
                JOIN rtxnstathist rsh
                    ON r.rtxnnbr = rsh.rtxnnbr
                    AND r.acctnbr = rsh.acctnbr
                    AND rsh.actdatetime = (
                        SELECT MAX(z.actdatetime)
                        FROM rtxnstathist z
                        WHERE rsh.acctnbr = z.acctnbr
                        AND rsh.rtxnnbr = z.rtxnnbr
                        AND z.rtxnstatcd = 'C'
                    )
                JOIN acct a
                    ON rea.acctnbr = a.acctnbr
                WHERE rea.entityattribcd = 'CXCPMTID'
                AND a.mjaccttypcd <> 'GL'
                AND NOT EXISTS(
                    SELECT 1
                    FROM rtxnentityattrib rea_z
                    WHERE r.rtxnnbr = rea_z.rtxnnbr
                    AND r.acctnbr = rea_z.acctnbr
                    AND rea_z.entityattribcd = 'RECONDATE'
                )
            ),
            dnaReconGL          =>  qq(
                SELECT 
                    r.acctnbr,
                    r.rtxnnbr,
                    r.rtxntypcd,
                    r.tranamt,
                    r.currrtxnstatcd,
                    TO_CHAR(r.origpostdate,'MM/DD/YYYY') origpostdate,
                    TO_CHAR(r.datelastmaint,'MM/DD/YYYY') datelastmaint,
                    e.extrtxndesctext,
                    r.tracenbr
                FROM rtxn r
                JOIN rtxnstathist rsh
                    ON r.rtxnnbr = rsh.rtxnnbr
                    AND r.acctnbr = rsh.acctnbr
                    AND rsh.actdatetime = (
                        SELECT MAX(z.actdatetime)
                        FROM rtxnstathist z
                        WHERE rsh.acctnbr = z.acctnbr
                        AND rsh.rtxnnbr = z.rtxnnbr
                        AND z.rtxnstatcd = 'C'
                    )
                JOIN extrtxndesc e
                    ON r.extrtxndescnbr = e.extrtxndescnbr
                WHERE r.acctnbr = ?
                AND rtxntypcd = 'XDEP'
                AND NOT EXISTS(
                    SELECT 1
                    FROM rtxnentityattrib rea
                    WHERE r.rtxnnbr = rea.rtxnnbr
                    AND r.acctnbr = rea.acctnbr
                    AND rea.entityattribcd = 'RECONDATE'
                )
            ),
        },
    };
    
    if ( $self->{apwx}->{ARGV}->{USE_MAX_CREATED_DATETIME} eq 'Y' ){
        #TODO: change this to CASE statement; when NOT NULL p.ModifiedDate use it; else use p.CreatedDate
        foreach ( qw( ftAppToCard ftAppToDDA inNtwkToFtApp oonCardToFtApp oonDDAToFtApp ) ){
            next if ! $sql->{p2p}->{$_};
            $sql->{p2p}->{$_} =
                $sql->{p2p}->{$_}
                ."\n\t\t\t\tAND td.trandate < '" . $createdDateTime->{PAYMENT} . "'"    
        }
        
        foreach ( qw( dnaRecon dnaReconGL ) ){
            next if ! $sql->{dna}->{$_};
            $sql->{dna}->{$_} .=
                "\nAND rsh.actdatetime < TO_DATE('"
                . $createdDateTime->{PAYMENT}
                . "' , 'MM/DD/YYYY HH24:MI::SS' )";     
        }
        
        foreach ( qw( zelleToACH zelleNonACH ) ){
            next if ! $sql->{p2p}->{$_};
            $sql->{p2p}->{$_} .=
                "\nAND CreatedDate < "
                . "CASE "
                    . "WHEN DebitNetworkId = 'VISA'"
                        ." THEN '" . $createdDateTime->{DETAIL_RECORD}->{VISA}
    
                    ."' WHEN DebitNetworkId = 'MASTERCARD'"
                        . " THEN '"  .$createdDateTime->{DETAIL_RECORD}->{MASTERCARD}
                    . "' ELSE '" . $createdDateTime->{DETAIL_RECORD}->{MONEYSEND}
                . "' END";
        }   
    }
    
    return $sql;
}

sub getUpdateTranSql
{
    my $sql = {
        mc_zeldly       =>  qq(
            UPDATE OSIUPDATE.P2P_RECON_MC_ZELDLY
            SET RECON_DATE = SYSDATE
            WHERE P2P_TRAN_ID = ?
            AND TRANSACTION_TYPE = ?
        ),
        visa_rw3        =>  qq(
            UPDATE OSIUPDATE.P2P_RECON_VISA_RW3
            SET RECON_DATE = SYSDATE
            WHERE TRAN_ID = ?
            AND TRAN_DATE = ?
            AND TRAN_TIME = ?   
        ),
        dnaRecon        =>  qq(
            INSERT INTO OSIBANK.RTXNENTITYATTRIB(
                ACCTNBR,
                RTXNNBR,
                ENTITYATTRIBCD,
                RTXNENTITYATTRIBVALUE,
                DATELASTMAINT
            )
            VALUES(
                ?,
                ?,
                'RECONDATE',
                TRUNC(SYSDATE),
                SYSDATE
            )
        ),
        dnaReconGL      =>  qq(
            INSERT INTO OSIBANK.RTXNENTITYATTRIB(
                ACCTNBR,
                RTXNNBR,
                ENTITYATTRIBCD,
                RTXNENTITYATTRIBVALUE,
                DATELASTMAINT
            )
            VALUES(
                ?,
                ?,
                'RECONDATE',
                TRUNC(SYSDATE),
                SYSDATE
            )              
        ),
        payment         =>  qq(
            UPDATE Payment
            SET ReconcileDate = GETDATE()
            WHERE Id = ?            
        ),
        detailRecord    =>  qq(
            UPDATE DetailRecord
            SET ReconcileDate = GETDATE()
            WHERE Id = ?           
        ),
    };
    
    return $sql;
}

# private methods - should only to be called via dispatch table codref entries

sub _getReconGlTrans
{
    my ( $rawGlTrans, $ntwkOrgs ) = @_;
    
    my $glReconTrans = {};
    
    foreach my $rawGlTran ( @{ $rawGlTrans } ){
        my $extDesc = $rawGlTran->{EXTRTXNDESCTEXT};
        my $cxcPmtId;
        
        if ( $extDesc =~ /^First Tech/ ){
            $extDesc =~ s/\s//g;
            my @extDescAry = split /P2P-ACH/, $extDesc;
            
            $cxcPmtId = $extDescAry[1];
            
            $glReconTrans->{$cxcPmtId} = $rawGlTran;
        }
        else{
            my @extDescAry = split /\s/, $extDesc;
            
            # try this first
            if ( length $extDescAry[-1] == 12 ){
                
                my $orgId = substr $extDescAry[-1], 0, 3;
                
                if ( exists $ntwkOrgs->{$orgId} ){ # matches a valid Org Id
                    
                    $cxcPmtId = $extDescAry[-1];
                    
                    if ( exists $glReconTrans->{$cxcPmtId} ){
                         warn "Found duplicate CXCPmtId ( $cxcPmtId ) in Recon GL XDEP transactions";
                         next;
                    }
                    else{
                        $glReconTrans->{$cxcPmtId} = $rawGlTran;
                    }  
                }
            }
            else{
                # check the rest of the array in case the last element wasn't the CXC Payment Id
                foreach ( @extDescAry ){
                    if ( length $_ == 12 ){ # potenitally a CXC Payment Id
                        my $orgId = substr $_, 0, 3; # first 3 chars should be a valid EWS Org Id
                        
                        if ( exists $ntwkOrgs->{$orgId} ){ # matches a valid Org Id
                            
                            $cxcPmtId = $_;
                            
                            if ( exists $glReconTrans->{$cxcPmtId} ){
                                warn "Found duplicate CXCPmtId ( $cxcPmtId ) in Recon GL XDEP transactions";
                                next;
                            }
                            else{
                                $glReconTrans->{$cxcPmtId} = $rawGlTran;
                                last;
                            }  
                        }
                    }
                }                
            }
        
            if ( ! $cxcPmtId ){
                warn
                    "CXC Payment ID not found in GL EXTRTXNDESC\n"
                    . "Acctnbr: " . "$rawGlTran->{ACCTNBR}\n"
                    . "Rtxn Nbr: " . "$rawGlTran->{RTXNNBR}\n";
                my $stop;    
            }

        }
    }
    
    return $glReconTrans;
}

sub _reconInNtwkToFtApp
{
    my ( $args ) = @_;
    
    say "Reconciling In-Network to FT App transactions";
    
    my ( @updateReconDateAry, @reconciled, @unreconciled );
    
    my $reconGlTrans = _getReconGlTrans( $args->{transToReconcile}->{dna}->{dnaReconGL}, $args->{inNtwkOrgs} );
    
    my $dnaTrans = $args->{transToReconcile}->{dna}->{dnaRecon};
    
    foreach my $inNtwkTran ( @{ $args->{transToReconcile}->{p2p}->{inNtwkToFtApp} } ){
        my $cxcPmtId = $inNtwkTran->{CXCPaymentID} || 'NULL';
        my $pmtId = $inNtwkTran->{Id}; # PK in P2P Payment table
        my $acctnbr = $inNtwkTran->{DefaultAccountNo};
        my $tranAmt = $inNtwkTran->{Amount};
        my $tranType = $inNtwkTran->{TransactionType};
        # my $createdDate = $inNtwkTran->{CreatedDate} || 'NULL';
        my $createdDate = $inNtwkTran->{TranDate} || 'NULL';
        
        # placeholders; will overwrite with the matching applicable value if found
        my $rtxnnbr = 'N/A'; 
        my $ntwkTranId = 'N/A';
        my $ntwkCd = 'N/A';
        my $reconciledYN = 'N';
        
        if ( $reconGlTrans->{$cxcPmtId} ){ # first, match CXCPMTID to a GL XDEP RTXN
            
            if ( abs( $tranAmt) == abs( $reconGlTrans->{$cxcPmtId}->{TRANAMT} ) ){ # then match to GL tran amount
                
                if ( $dnaTrans->{$cxcPmtId} ){ # then match CXCPMTID to RTXN Entity Attribute
                    
                    if ( $dnaTrans->{$cxcPmtId}->{$acctnbr} ){ # then match P2P AccountNo to RTXN Acctnbr
                        
                        $rtxnnbr = $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RTXNNBR};
                        
                        if ( abs( $tranAmt ) == abs( $dnaTrans->{$cxcPmtId}->{$acctnbr}->{TRANAMT} ) ){ #then match RTXN tran amount

                            # reconciled
                            $reconciledYN = 'Y';
                            $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RECONCILED} = 1;
                            $reconGlTrans->{$cxcPmtId}->{RECONCILED} = 1; # mark GL XDEP as reconciled
                            
                            push @reconciled,
                                [
                                 $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                                 substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                 'Reconciled - Match GL XDEP, match DNA RTXN'
                                ];     
                        }
                        else{
                            push
                                @unreconciled,
                                [
                                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                                    substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                    'Unreconciled - Match GL XDEP, match DNA RTXN, DNA RTXN TranAmt mismatch'
                                ];   
                        }                        
                    }
                    else{
                             push
                                @unreconciled,
                                [
                                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                                    substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                    'Unreconciled - Match GL XDEP, match DNA CXCPMTID, DNA RTXN ACCTNBR mismatch'
                                ];                        
                    }
                }
                else{
                    push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                            substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - Match to GL XDEP, no match DNA RTXN'
                        ];
                }
            }
            else{
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                        substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - Match GL XDEP, GL TranAmt mismatch'
                    ];
            }
        }
        else{
            push
                @unreconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                    substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Unreconciled - No match GL XDEP'
                ];    
        }    
    }
    
    $args->{transToReconcile}->{dna}->{dnaReconGL} = $reconGlTrans;
    
    @updateReconDateAry = map{ [ $_->[0] ] } @reconciled; 
    
    return ( \@updateReconDateAry, \@reconciled, \@unreconciled );
}

sub _reconOONDDAToFtApp
{
    my ( $args ) = @_;
    
    say "Reconciling Out-Of-Network DDA to FT App transactions";
    
    my ( @updateReconDateAry, @reconciled, @unreconciled );
    
    foreach my $oonDDATran ( @{ $args->{transToReconcile}->{p2p}->{oonDDAToFtApp} } ){
        my $cxcPmtId = $oonDDATran->{CXCPaymentID} || 'NULL';
        my $pmtId = $oonDDATran->{Id}; # PK in P2P Payment table
        my $tranAmt = $oonDDATran->{Amount};
        my $tranType = $oonDDATran->{TransactionType};
        my $acctnbr = $oonDDATran->{DefaultAccountNo};
        my $createdDate = $oonDDATran->{TranDate} || 'NULL';
        # my $createdDate = $oonDDATran->{CreatedDate} || 'NULL';
        my $achStatus = $oonDDATran->{ACHProcessStatus};
        
        # placeholders; will overwrite with the matching applicable value if found
        my $rtxnnbr = 'N/A'; 
        my $ntwkTranId = 'N/A';
        my $ntwkCd = 'N/A';
        my $reconciledYN = 'N';
        
        if ( $achStatus && uc $achStatus eq 'SENT' ){
            
            # reconciled
            $reconciledYN = 'Y';
            
            push
                @reconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                    substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Reconciled - ACH sent as of reconcile date'
                ];
        }
        else{
            push
                @unreconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                    substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Unreconciled - ACH not sent as of reconciled date' 
                ];
        }
    }
    
    @updateReconDateAry = map{ [ $_->[0] ] } @reconciled; 
    
    return ( \@updateReconDateAry, \@reconciled, \@unreconciled );
}

sub _reconOONCardToFtApp
{
    my ( $args ) = @_;
    
    say "Reconciling Out-of-Network Card to FT App transactions";
    
    my ( @updateReconDateAry, @reconciled, @unreconciled );
    
    my $dnaTrans = $args->{transToReconcile}->{dna}->{dnaRecon};
    
    foreach my $oonCardTran ( @{ $args->{transToReconcile}->{p2p}->{oonCardToFtApp} } ){
        my $cxcPmtId = $oonCardTran->{CXCPaymentID} || 'NULL';
        my $pmtId = $oonCardTran->{Id}; # PK in P2P Payment table
        my $tranAmt = $oonCardTran->{Amount};
        my $tranType = $oonCardTran->{TransactionType};
        my $acctnbr = $oonCardTran->{DefaultAccountNo};
        my $createdDate = $oonCardTran->{TranDate} || 'NULL';
        # my $createdDate = $oonCardTran->{CreatedDate} || 'NULL';

        # placeholders; will overwrite with the matching applicable value if found
        my $rtxnnbr = 'N/A'; 
        my $ntwkTranId = 'N/A';
        my $ntwkCd = 'N/A';
        my $reconciledYN = 'N';
        
        if ( exists $dnaTrans->{$cxcPmtId} ){
            
            if ( exists $dnaTrans->{$cxcPmtId}->{$acctnbr} ){
                
                $rtxnnbr = $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RTXNNBR};
                
                if ( abs( $tranAmt ) == abs( $dnaTrans->{$cxcPmtId}->{$acctnbr}->{TRANAMT} ) ){
        
                    #reconciled
                    my $reconciledYN = 'Y';
                    $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RECONCILED} = 1; 
                    
                    push
                        @reconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Reconciled - DNA RTXN match'
                        ];
                }
                else
                {
                    # CXCPmtId matched but TranAmount did not
                    push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - DNA RTXN match, Tran Amount mismatch'
                        ];
                }                
            }
            else{
                # CXCPMTID matched but DNA Acctnbr did not
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - DNA RTXN CXCPMTID match, DNA RTXN ACCTNBR mismatch'
                    ];                
            }
        }
        else{
            push
                @unreconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                    $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Unreconciled - CXCPMTID did not match any transactions in DNA RTXN'
                ];   
        }   
    }        
    
    @updateReconDateAry = map{ [ $_->[0] ] } @reconciled; 
    
    return ( \@updateReconDateAry, \@reconciled, \@unreconciled );
}

sub _reconFtAppToCard
{
    my ( $args ) = @_;
    
    say "Reconciling FT App to Card transactions";
    
    my ( @updateReconDateAry, @reconciled, @unreconciled );
    
    my $dnaTrans = $args->{transToReconcile}->{dna}->{dnaRecon};
    
    foreach my $ftAppToCardTran ( @{ $args->{transToReconcile}->{p2p}->{ftAppToCard} } ){
        my $cxcPmtId = $ftAppToCardTran->{CXCPaymentID};
        my $pmtId = $ftAppToCardTran->{Id};
        my $tranAmt = $ftAppToCardTran->{Amount};
        my $tranType = $ftAppToCardTran->{TransactionType};
        my $acctnbr = $ftAppToCardTran->{SenderAccountNo};
        my $createdDate = $ftAppToCardTran->{TranDate};
        # my $createdDate = $ftAppToCardTran->{CreatedDate};

        # placeholders; will overwrite with an applicable value, if found
        my $rtxnnbr = 'N/A'; 
        my $ntwkTranId = 'N/A';
        my $ntwkCd = 'N/A';
        my $reconciledYN = 'N';
        
        if ( exists $dnaTrans->{$cxcPmtId} ){
            
            if ( exists $dnaTrans->{$cxcPmtId}->{$acctnbr} ){
                
                my $rtxnnbr = $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RTXNNBR};
                
                if ( abs( $tranAmt ) == abs( $dnaTrans->{$cxcPmtId}->{$acctnbr}->{TRANAMT} ) ){
                    
                    # reconciled
                    my $reconciledYN = 'Y';
                    $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RECONCILED} = 1;
                    
                    push
                        @reconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                            substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Reconciled - DNA RTXN match'
                        ];
                }
                else
                {
                    # CXCPmtId matched but TranAmount did not
                    push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                            substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - DNA RTXN match, Tran Amount mismatch'
                        ];
                }                
            }
            else{
                # CXCPmtId matched but DNA ACCTNBR did not
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                        substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - DNA CXCPMTID match, DNA RTXN ACCTNBR mismatch'
                    ];                
            }
        }
        else{
            push
                @unreconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt,
                    substr(  $createdDate,0,16 ), $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Unreconciled - CXCPMTID did not match any transactions in DNA RTXN'
                ];   
        }   
    }
    
    @updateReconDateAry = map{ [ $_->[0] ] } @reconciled; 
    
    return ( \@updateReconDateAry, \@reconciled, \@unreconciled );
}

sub _reconFtAppToDDA
{
    my ( $args ) = @_;
    
    say "Reconciling FT App to DDA transactions";

    my ( @updateReconDateAry, @reconciled, @unreconciled );
    
    my $dnaTrans = $args->{transToReconcile}->{dna}->{dnaRecon};
    
    foreach my $ftAppToDDATran ( @{ $args->{transToReconcile}->{p2p}->{ftAppToDDA} } ){
        my $pmtId = $ftAppToDDATran->{Id};
        my $cxcPmtId = $ftAppToDDATran->{CXCPaymentID} || 'NULL';
        my $tranAmt = $ftAppToDDATran->{Amount};
        my $tranType = $ftAppToDDATran->{TransactionType},
        my $acctnbr = $ftAppToDDATran->{SenderAccountNo};
        my $createdDate = $ftAppToDDATran->{TranDate} || 'NULL';
        # my $createdDate = $ftAppToDDATran->{CreatedDate} || 'NULL';

        # placeholders; will overwrite with the matching applicable value if found
        my $rtxnnbr = 'N/A'; 
        my $ntwkTranId = 'N/A';
        my $ntwkCd = 'N/A';
        my $reconciledYN = 'N';
        
        if ( exists $dnaTrans->{$cxcPmtId} ){ # match CXC Payment Id to RTXN
            
            if ( exists $dnaTrans->{$cxcPmtId}->{$acctnbr} ){ # match P2P accountno to RTXN acctnbr
                
                if ( $ftAppToDDATran->{ACHProcessStatus} && $ftAppToDDATran->{ACHProcessStatus} eq 'SENT' ){
                    
                    $rtxnnbr = $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RTXNNBR};
                    
                    if ( abs( $tranAmt ) == abs( $dnaTrans->{$cxcPmtId}->{$acctnbr}->{TRANAMT} ) ){
                        
                        #reconciled
                        my $reconciledYN = 'Y';
                        $dnaTrans->{$cxcPmtId}->{$acctnbr}->{RECONCILED} = 1;
                    
                        push
                            @reconciled,
                            [
                                $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                                $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                'Reconciled - DNA RTXN'
                            ];
                    }
                    else
                    {
                        # CXCPmtId matched but TranAmount did not
                        push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - DNA RTXN match, Tran Amount mismatch'
                        ];
                    }                       
                }
                else{
                    push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - DNA RTXN match, ACH Process Status is not SENT'
                    ];                    
                }
            }
            else{
                push
                @unreconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                    $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Unreconciled - DNA CXCPMTID match, DNA Acctnbr mismatch'
                ];                
            }
        }
        else{
            push
                @unreconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                    $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Unreconciled - CXCPMTID did not match any transactions in DNA RTXN'
                ];   
        }   
    }
    
    @updateReconDateAry = map{ [ $_->[0] ] } @reconciled; 
    
    return ( \@updateReconDateAry, \@reconciled, \@unreconciled );    
}

sub _reconZelleAch
{
    my ( $args ) = @_;
    
    say "Reconciling Zelle ACH transactions";
    
    if ( ! exists $args->{transToReconcile}->{dna}->{mc_zeldly} ){
        warn
        "Master Card ZELDLY recon file data does not exist in 'transToReconcile'\n"
        . "You cannot reconcile Zelle ACH transactions without this data\n"
        . "Check P2P Recon config file and verify MC/ZELDLY network/filecode is enabled";
        
        return;
    }
    
    my $mcZelDly = $args->{transToReconcile}->{dna}->{mc_zeldly};
    
    my ( @updateReconDateAry, @reconciled, @unreconciled );
    
    my %zelleToMcOffsetTranTyp = (
        DEBIT   =>  'FUNDING', 
        CREDIT  =>  'PAYMENT',
        REVDBT  =>  'FUNDING_REVERSAL',   
    );
    
    foreach my $zelleAchTran ( @{ $args->{transToReconcile}->{p2p}->{zelleToACH} } ){

        # Zelle TranId is usually composed of SystemTraceAuditNumber + 'TTT' + RetrievalReferenceNumber
        my $pmtId = $zelleAchTran->{Id};
        my $cxcPmtId = $zelleAchTran->{PaymentCXCPaymentID};
        my $ntwkTranId = $zelleAchTran->{DebitNetworkTransactionId};
        # my $zAcctnbr = $zelleAchTran->{SenderAccountNo};
        my $createdDate = $zelleAchTran->{CreatedDate} || 'NULL';
        my $tranAmt = $zelleAchTran->{PaymentAmount};
        my $tranType = $zelleAchTran->{DebitNetworkTransactionType};
        
        # sometimes Zelle TranId just consists of the SystemTraceAuditNumber + 'TTT'
        my @ntwkTranIdAry = split /TTT/, $zelleAchTran->{DebitNetworkTransactionId};
        my $ntwkTranIdSmall = $ntwkTranIdAry[0] . 'TTT';
        
        # placeholders; will overwrite with the matching applicable value if found
        my $rtxnnbr = 'N/A'; 
        my $acctnbr = 'N/A';
        my $ntwkCd = 'N/A';
        my $reconciledYN = 'N';

        # check Master Card recon file records for match to Zelle TranId
        if( exists $mcZelDly->{$ntwkTranId} ){
            my $mcTranType = $zelleToMcOffsetTranTyp{$tranType};
            # verify MC tran has the correct offset TranType           
            if ( $mcZelDly->{$ntwkTranId}->{ $mcTranType } ){           
                my $mcTran = $mcZelDly->{$ntwkTranId}->{ $mcTranType };
                my $ntwkCd = 'MC';
                my $mcTranAmt = $mcTran->{TRANSACTION_AMOUNT};
                
                if ( $zelleAchTran->{ACHProcessStatus} && $zelleAchTran->{ACHProcessStatus} eq 'SENT'){
                    
                    if ( $tranAmt == $mcTranAmt ){
                        
                        # reconciled
                        my $reconciledYN = 'Y';
                        $mcTran->{RECONCILED} = 1;
                        
                        push
                            @reconciled,
                            [
                                $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                                $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                'Reconciled - MC recon files'
                            ]; 
                    }
                    else
                    {
                        # TranId matched but TranAmount did not
                        push
                            @unreconciled,
                            [
                                $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                                $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                'Unreconciled - MC TranId match, Tran Amount mismatch'
                            ]; 
                    }                    
                }
                else{
                    # TranId matched but ACH Process Status not 'SENT'
                    push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - MC TranId match, Unreconciled - ACH Process Status is not SENT'
                        ];                    
                }
            }
            else{
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - MC TranId match, Could not find MC tran with correct offset TranCd'
                    ];
            }
        }
        # try to match Master Card recon file records again using abbreviated Zelle TranId
        elsif( exists $mcZelDly->{$ntwkTranIdSmall} ){
            
            $ntwkTranId = $ntwkTranIdSmall;
            
            my $mcTranType = $zelleToMcOffsetTranTyp{$tranType};
           
           if ( $mcZelDly->{$ntwkTranId}->{ $mcTranType } ){
                
                my $mcTran = $mcZelDly->{$ntwkTranId}->{ $mcTranType };
            
                $ntwkCd = 'MC';
                
                my $mcTranAmt = $mcTran->{TRANSACTION_AMOUNT};
                
                if ( $zelleAchTran->{ACHProcessStatus} && $zelleAchTran->{ACHProcessStatus} eq 'SENT'){
                    
                    if ( abs( $tranAmt ) == abs( $mcTranAmt ) ){
                        
                        # reconciled
                        my $reconciledYN = 'Y';
                        $mcTran->{RECONCILED} = 1;
                    
                        push
                            @reconciled,
                            [
                                $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                                $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                'Reconciled - MC recon files'
                            ]
                    }
                    else{
                        # TranId matched but TranAmount did not
                        push
                            @unreconciled,
                            [
                                $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                                $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                                'Unreconciled - MC TranId match, Tran Amount mismatch'
                            ];
                    }                    
                }
                else{
                    # TranId matched but ACH Process Status not 'SENT'
                    push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - MC TranId match, ACH Process Status is not SENT'
                        ];                      
                }
            }
           else{
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - MC TranId match, Could not find MC tran with correct offset TranCd'
                    ];
           }
        }
        else{
            
            if ( $zelleAchTran->{ACHProcessStatus} && $zelleAchTran->{ACHProcessStatus} eq 'SENT' ){
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - No match MC TranId, ACH Process Status is SENT'
                    ];                  
            }
            else{
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - No match MC TranId, no ACH Process Status SENT'
                    ];                
            }
        }
    }
    
    @updateReconDateAry = map{ [ $_->[0] ] } @reconciled; 
    
    return ( \@updateReconDateAry, \@reconciled, \@unreconciled );
}

sub _reconZelleNonAch
{
    my ( $args ) = @_;
    
    say "Reconciling Zelle Non-ACH transactions";
    
    if ( ! exists $args->{transToReconcile}->{dna}->{mc_zeldly} ){
        warn
        "Master Card ZELDLY recon file data does not exist in 'transToReconcile'\n"
        . "You cannot reconcile Zelle Non-ACH transactions without this data\n"
        . "Check P2P Recon config file and verify MC/ZELDLY network/filecode is enabled";
        
        return;
    }
    
    if ( ! exists $args->{transToReconcile}->{dna}->{visa_rw3} ){
        warn
        "Visa ZELRW3 recon file data does not exist in 'transToReconcile'\n"
        . "You cannot reconcile Zelle Non-ACH transactions without this data\n"
        . "Check P2P Recon config file and verify VISA/ZELRW3 network/filecode is enabled";
        
        return;
    }
    
    my $mcZelDly = $args->{transToReconcile}->{dna}->{mc_zeldly};
    my $visaRW3 = $args->{transToReconcile}->{dna}->{visa_rw3};
    
    my ( @updateReconDateAry, @reconciled, @unreconciled );
    
    my %zelleToMcOffsetTranTyp = (
        DEBIT   =>  'FUNDING', 
        CREDIT  =>  'PAYMENT',
        REVDBT  =>  'FUNDING_REVERSAL',   
    );
    
    foreach my $zelleTran ( @{ $args->{transToReconcile}->{p2p}->{zelleNonACH} } ){
        
        my $pmtId = $zelleTran->{Id};
        my $cxcPmtId = $zelleTran->{PaymentCXCPaymentID};
        
        # Zelle TranId is usually composed of SystemTraceAuditNumber + 'TTT' + RetrievalReferenceNumber
        # if 'Source' was MasterCard (vs. Mestro or MoneySend ), this will be the ReferenceID from MC ZELDLY
        my $ntwkTranId = $zelleTran->{DebitNetworkTransactionId};

        # my $zAcctnbr = $zelleAchTran->{SenderAccountNo};
        my $createdDate = $zelleTran->{CreatedDate};
        my $tranAmt = $zelleTran->{PaymentAmount};
        my $tranType = $zelleTran->{DebitNetworkTransactionType};
        
        # sometimes Zelle TranId just consists of the SystemTraceAuditNumber + 'TTT'
        my $ntwkTranIdSmall;
        
        if ( $ntwkTranId =~ /TTT/ ){
            my @ntwkTranIdAry = split /TTT/, $ntwkTranId;
            $ntwkTranIdSmall = $ntwkTranIdAry[0] . 'TTT';            
        }

        # placeholders; will overwrite with the matching applicable value if found
        my $rtxnnbr = 'N/A'; 
        my $acctnbr = 'N/A';
        my $ntwkCd = 'N/A';
        my $reconciledYN = 'N';
        
        # check Master Card recon file records for match to Zelle TranId
        if( exists $mcZelDly->{$ntwkTranId} ){
            my $mcTranType = $zelleToMcOffsetTranTyp{$tranType};
            # verify MC tran has the correct offset TranType           
            if ( $mcZelDly->{$ntwkTranId}->{ $mcTranType } ){           
                my $mcTran = $mcZelDly->{$ntwkTranId}->{ $mcTranType };
                my $ntwkCd = 'MC';
                my $mcTranAmt = $mcTran->{TRANSACTION_AMOUNT};
                
                if ( $tranAmt == $mcTranAmt ){
                    
                    # reconciled
                    my $reconciledYN = 'Y';
                    $mcTran->{RECONCILED} = 1;
                    
                    push
                        @reconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Reconciled - MC recon files'
                        ]; 
                }
                else
                {
                    # TranId matched but TranAmount did not
                    push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - MC TranId match, Tran Amount mismatch'
                        ]; 
                }
            }
            else{
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - Network TranId did not match any network recon files'
                    ];
            }
        }
        # try to match Master Card recon file records again using abbreviated Zelle TranId
        elsif( $ntwkTranIdSmall && exists $mcZelDly->{$ntwkTranIdSmall} ){
            
            $ntwkTranId = $ntwkTranIdSmall;
            
            my $mcTranType = $zelleToMcOffsetTranTyp{$tranType};
           
           if ( $mcZelDly->{$ntwkTranId}->{ $mcTranType } ){
                
                my $mcTran = $mcZelDly->{$ntwkTranId}->{ $mcTranType };
            
                $ntwkCd = 'MC';
                
                my $mcTranAmt = $mcTran->{TRANSACTION_AMOUNT};
                
                if ( abs( $tranAmt ) == abs( $mcTranAmt ) ){
                    
                    # reconciled
                    my $reconciledYN = 'Y';
                    $mcTran->{RECONCILED} = 1;
                
                    push
                        @reconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Reconciled - MC recon files'
                        ]
                }
                else{
                    # TranId matched but TranAmount did not
                    push
                        @unreconciled,
                        [
                            $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                            $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                            'Unreconciled - MC TranId match, Tran Amount mismatch'
                        ];
                }
            }
           else{
                # nothing matched
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - MC TranId match, Could not find MC tran with correct offset TranCd'
                    ];
           }
        }
        # Check Visa recon file records for match to Zelle TranId
        elsif( exists $visaRW3->{$ntwkTranId} ){
            
            $ntwkCd = 'VISA';
            
            my $vTranAmt = $visaRW3->{$ntwkTranId}->{TRAN_AMOUNT};
            
            if ( abs( $tranAmt ) == abs( $vTranAmt ) ){
                
                # reconciled
                my $reconciledYN = 'Y';
                $visaRW3->{$ntwkTranId}->{RECONCILED} = 1;
                
                push
                    @reconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Reconciled - Visa recon files'
                    ];
            }
            else
            {
                # Tran Id matched but Tran Amount did not
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - Visa TranId match, Tran Amount mismatch'
                    ];                
            }        
        }
        # try to match Visa recon file records again using abbreviated Zelle TranId
        elsif( $ntwkTranIdSmall && exists $visaRW3->{$ntwkTranIdSmall} ){
            
            $ntwkCd = 'VISA';
            $ntwkTranId = $ntwkTranIdSmall;
            
            my $vTranAmt = $visaRW3->{$ntwkTranId}->{TRAN_AMOUNT};
            
            if ( abs( $tranAmt ) == abs( $vTranAmt ) ){
                
                # reconciled
                my $reconciledYN = 'Y';
                $visaRW3->{$ntwkTranId}->{RECONCILED} = 1;
                
                push
                    @reconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Reconciled - Visa recon files'
                    ]; 
            }
            else
            {
                # TranId matched but TranAmount did not
                push
                    @unreconciled,
                    [
                        $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                        $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                        'Unreconciled - Visa TranId match, Tran Amount mismatch'
                    ]; 
            }            
        }
        else{
            # nothing matched
            push
                @unreconciled,
                [
                    $pmtId, $cxcPmtId, $reconciledYN, $tranType, $tranAmt, substr(  $createdDate,0,16 ),
                    $acctnbr, $rtxnnbr, $ntwkCd, substr(  $ntwkTranId,0,40 ),
                    'Unreconciled - Network TranId did not match any network recon files'
                ];
        }
    }
    
    @updateReconDateAry = map{ [ $_->[0] ] } @reconciled;
    
    return ( \@updateReconDateAry, \@reconciled, \@unreconciled );
}

sub _reconDnaTrans
{
    my ( $args ) = @_;
    
    say "Reconciling DNA RTXN transactions";
    
    my $tranType = $args->{tranType};
    
    my ( @updateAry, @reconciled, @unreconciled );
    
    my %dnaTranCdToCrDr = (
        XDEP    =>  'CREDIT', 
        DEP     =>  'CREDIT',
        DEPD    =>  'CREDIT',
        XWTH    =>  'CREDIT',
        WTH     =>  'DEBIT',
        WTHD    =>  'DEBIT', 
    );

    foreach my $cxcPmtId ( keys %{ $args->{transToReconcile} } ){
        foreach my $acctnbr ( keys %{ $args->{transToReconcile}->{$cxcPmtId} } ){
            my $rtxnTypCd = $args->{transToReconcile}->{$cxcPmtId}->{$acctnbr}->{RTXNTYPCD};
            my $tranId = $args->{transToReconcile}->{$cxcPmtId}->{$acctnbr}->{RTXNNBR};
            my $tranCd = $dnaTranCdToCrDr{$rtxnTypCd};
            my $tranAmt = sprintf "%-.2f", abs($args->{transToReconcile}->{$cxcPmtId}->{$acctnbr}->{TRANAMT} );
            my $tranDate = $args->{transToReconcile}->{$cxcPmtId}->{$acctnbr}->{ORIGPOSTDATE};
            
            if ( $args->{transToReconcile}->{$cxcPmtId}->{$acctnbr}->{RECONCILED} ){
                push @updateAry, [ $acctnbr, $tranId ];
                push @reconciled, [ $tranId, $cxcPmtId, 'Y', 'RTXN', $tranDate, $tranCd, $tranAmt, $acctnbr, 'N/A', 'Reconciled' ];
            }
            else{
                push @unreconciled, [ $tranId, $cxcPmtId, 'N', 'RTXN', $tranDate, $tranCd, $tranAmt, $acctnbr, 'N/A', 'Unreconciled' ];    
            }
        }           
    } 

    return ( \@updateAry, \@reconciled, \@unreconciled );
}

sub _reconDnaGlTrans
{
    my ( $args ) = @_;
    
    say "Reconciling DNA GL transactions";
    
    my $tranType = $args->{tranType};
    
    my ( @updateAry, @reconciled, @unreconciled );
    
    my %dnaTranCdToCrDr = (
        XDEP    =>  'CREDIT', 
        DEP     =>  'CREDIT',
        DEPD    =>  'CREDIT',
        XWTH    =>  'CREDIT',
        WTH     =>  'DEBIT',
        WTHD    =>  'DEBIT', 
    );
    
    foreach my $cxcPmtId ( keys %{ $args->{transToReconcile} } ){
            my $acctnbr = $args->{transToReconcile}->{$cxcPmtId}->{ACCTNBR};
            my $rtxnTypCd = $args->{transToReconcile}->{$cxcPmtId}->{RTXNTYPCD};
            my $tranId = $args->{transToReconcile}->{$cxcPmtId}->{RTXNNBR};
            my $tranCd = $dnaTranCdToCrDr{$rtxnTypCd};
            my $tranAmt = sprintf "%-.2f", abs( $args->{transToReconcile}->{$cxcPmtId}->{TRANAMT} );
            my $tranDate = $args->{transToReconcile}->{$cxcPmtId}->{ORIGPOSTDATE};
            
            if ( $args->{transToReconcile}->{$cxcPmtId}->{RECONCILED} ){
                push @updateAry, [ $acctnbr, $tranId ];
                push @reconciled, [ $tranId, $cxcPmtId, 'Y', 'GL', $tranDate, $tranCd, $tranAmt, $acctnbr, 'N/A', 'Reconciled' ];
            }
            else{
                push @unreconciled, [ $tranId, $cxcPmtId, 'Y', 'GL', $tranDate, $tranCd, $tranAmt, $acctnbr, 'N/A', 'Unreconciled' ];    
            }
    }
    
    return ( \@updateAry, \@reconciled, \@unreconciled );
}

sub _reconMcZelDly
{
    my ( $args ) = @_;
    
    say "Reconciling Master Card ZELDLY transactions";
    
    my $tranType = $args->{tranType};
    
    my ( @updateAry, @reconciled, @unreconciled );
    
    my %mcTranTypToCrDr = (
        PAYMENT             =>  'DEBIT', 
        FUNDING             =>  'CREDIT',
        FUNDING_REVERSAL    =>  'DEBIT',   
    );
    
    foreach my $tranId ( keys %{ $args->{transToReconcile} } ){
        foreach my $mcTranCd ( keys %{ $args->{transToReconcile}->{$tranId} } ){
            my $mcTran = $args->{transToReconcile}->{$tranId}->{$mcTranCd};
            my $cardnbr = $mcTran->{ACCOUNT_NUMBER};
            my $tranCd = $mcTranTypToCrDr{$mcTranCd};
            my $tranAmt = $mcTran->{TRANSACTION_AMOUNT};
 
            my $tranDate = ( split /\s/, $mcTran->{DATETIME_CREATED} )[0];
            
            if ( $mcTran->{RECONCILED} ){
                    push @updateAry, [ $tranId, $mcTranCd ];
                    push @reconciled, [ $tranId, 'N/A', 'Y', 'MC', $tranDate, $tranCd, abs($tranAmt), 'N/A', $cardnbr, 'Reconciled' ];                
            }
            else{
                    push @unreconciled, [ $tranId, 'N/A', 'N', 'MC', $tranDate, $tranCd, abs($tranAmt), 'N/A', $cardnbr, 'Unreconciled' ];    
            }            
        }

    }
    
    return ( \@updateAry, \@reconciled, \@unreconciled );    
}

sub _reconVisaRw3
{
    my ( $args ) = @_;
    
    say "Reconciling Visa RW3 transactions";
    
    my $tranType = $args->{tranType};
    
    my ( @updateAry, @reconciled, @unreconciled );
    
    foreach my $tranId ( keys %{ $args->{transToReconcile} } ){
            my $acctnbr = 'N/A';
            my $cardnbr = $args->{transToReconcile}->{$tranId}->{CARD_NUMBER};
            my $tranCd = $args->{transToReconcile}->{$tranId}->{TRAN_CODE};
            my $tranAmt = $args->{transToReconcile}->{$tranId}->{TRAN_AMOUNT};
            my $tranDate =
                join '/',
                substr( $args->{transToReconcile}->{$tranId}->{TRAN_DATE}, 0, 2 ),
                substr( $args->{transToReconcile}->{$tranId}->{TRAN_DATE}, 2, 2 );
                
        if ( $args->{transToReconcile}->{$tranId}->{RECONCILED} ){
                push @updateAry, [
                    $tranId,
                    $args->{transToReconcile}->{$tranId}->{TRAN_DATE},
                    $args->{transToReconcile}->{$tranId}->{TRAN_TIME}
                ];
                
                push @reconciled, [ $tranId, 'N/A', 'Y', 'VISA', $tranDate, $tranCd, abs($tranAmt), $acctnbr, $cardnbr, 'Reconciled' ];                
        }
        else{
                push @unreconciled, [ $tranId, 'N/A', 'Y', 'VISA', $tranDate, $tranCd, abs($tranAmt), $acctnbr, $cardnbr, 'Unreconciled' ];    
        }
    }
    
    return ( \@updateAry, \@reconciled, \@unreconciled );    
}

1