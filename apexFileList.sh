#!/bin/bash 

###############################################
# VARIABLE DECLARATIONS 
###############################################
    REMOTE_USERNAME="root"
    HOSTS_FILE="/etc/hosts"
    BASENAME="/etc"
###############################################
# FORMATTING OPTIONS 
###############################################
    BOX_CHAR="#"
    END_CHAR="#"
    S="SIZE"
    F="NAME"
    T="TIME"
    COL_S=15
    COL_T=40
    COL_F=0
###############################################


###############################################
# FUNCTION IMPLEMENTATIONS
###############################################

    # createLine prints a line determined by WIDTH
    createLine (){
        WIDTH=$1
        for (( length=1; length<=$WIDTH+4; length++))
            do
            echo -n $BOX_CHAR
        done
        echo    
    }

    # displayBox prints a box around a string
    displayBox (){
        STR=$1
        STR_LENGTH=${#STR}
        createLine $STR_LENGTH
        echo "${END_CHAR} ${STR} ${END_CHAR}"
        createLine $STR_LENGTH
    }

    # printFiles displays files for specific location
    printFiles () {
        echo "Displaying files..."
        createLine 60
        printf "%-${COL_S}s %-${COL_T}s %-${COL_F}s \n" $S $T $F 
        find $BASENAME -type f -printf "%-${COL_S}s %-${COL_T}t %-${COL_F}f\n"
        #find /usr/local/bin -type f -printf "%-$15s %-$40t %-$0f\n"
    }

    # sshFileSearch    
    sshFileSearch (){
        HOST_SERVER=$1
        echo "Connecting to remote host using"
        echo "Username: "${REMOTE_USERNAME}
        echo "Hostname: "${HOST_SERVER}
        createLine 60
        ssh $REMOTE_USERNAME@$HOST_SERVER ' 
                    ##### Remote Config Vars #########
                    S="SIZE"
                    F="NAME"
                    T="TIME"
                    COL_S=15
                    COL_T=40
                    COL_F=0
                    BASENAME="/etc"
                    ##################################
                    
                    printfiles () {
                        echo "Displaying files..."
                        printf "%-${COL_S}s %-${COL_T}s %-${COL_F}s \n" $S $T $F 
                        find $BASENAME -type f -printf "%-${COL_S}s %-${COL_T}t %-${COL_F}f\n"
                    }
                    printfiles
                '
    }

    # searchHostsFile searches through the hosts file on the host
    searchHostsFile (){
        SEARCH_KEY=$1
        COUNT=$(cut -f 2-3 $HOSTS_FILE | grep -c $SEARCH_KEY) 
        
        for (( line_num=1; line_num<=$COUNT; line_num++))
            do
            LINE="${line_num}p"
            HOST=$(cut -f 2-3 $HOSTS_FILE | grep $SEARCH_KEY | sed -n $LINE)
            echo "Found ${HOST}.  Connecting..."
            createLine 60
            sshFileSearch $HOST
        done
    }

###############################################
# MAIN IMPLEMENTATION
###############################################
    echo    
    displayBox "The name of the localhost is: ${HOSTNAME}"
    echo
    printFiles
    
    echo    
    displayBox "SHOWING ZCs"
    echo
    searchHostsFile "zc"
    
    echo
    displayBox "SHOWING ICSs"
    echo
    searchHostsFile "ics"

