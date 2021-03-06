#!/bin/bash
VERSION="4.4.1 [29 Jun 2016]"
if [ -z "$TEMP" ]; then
	for TEMP in /tmp /var/tmp /var/temp /temp $PWD; do
		[ -d "$TEMP" ] && break
	done
fi

# Define functions for later use
send_message() {
	# single parameter is the message text
	MESSAGE="$1\n\nThis message was generated by $THIS v$VERSION\nhttp://www.timedicer.co.uk/programs/help/$THIS.php"
	MAILNOTSENT=1
	if [ -n "$EMAIL" ]; then
		echo -e "To:$EMAIL\nSubject:$MESSAGE" | sendmail $EMAIL; MAILNOTSENT=$?
	fi
	if [ -z "$QUIET" ]; then
		echo -en "\n\nThis message has "
		[ "$MAILNOTSENT" -gt 0 ] && echo -n "*not* "
		echo -e "been emailed:\n\n$MESSAGE"
	fi
}

check_credit_level() {
	#parameters: website username password warning_credit_level_in_cents
	#example: www.voipdiscount.com myaccount mypassword 200
	unset CREDITCENTS
	# Show website
	if [ -z "$QUIET" ]; then
		[ -n "$VERBOSE" ] && echo -e "\n$1" || echo -n "$1 "
	fi
	# Set up cookiejar
	COOKIEJAR="$TEMP/$THIS-$(id -u)-$1-$2-cookiejar.txt"
	[[ -n $DEBUG ]] && echo "COOKIEJAR: '$COOKIEJAR'"
	if [ -n "$NEWCOOKIEJAR" ]; then
		rm -f "$COOKIEJAR"; touch "$COOKIEJAR"	#; chmod 600 "$COOKIEJAR"
		[ -z "$QUIET" ] && echo "  deleted any existing cookie jar"
	elif [ ! -f "$COOKIEJAR" ]; then
		touch "$COOKIEJAR"	#; chmod 600 "$COOKIEJAR"
		[ -n "$VERBOSE" ] && echo "  could not find any existing cookie jar"
	# Check whether cookie is still valid
	else
		#[ $(stat -c %a "$COOKIEJAR") -ne 600 ] && chmod 600 "$COOKIEJAR"
		FIRSTEXPIRE=$(grep "#Http" "$COOKIEJAR"|grep -v "deleted"|awk '{if ($5!=0) print $5}'|sort -u|head -n 1)
		if [ -n "$FIRSTEXPIRE" ]; then
			if [ $(date +%s) -gt $FIRSTEXPIRE ]; then
				# cookies have expired
				[ -n "$VERBOSE" ] && echo -n "  at least one login cookie has expired"
				if [ -n "$PAUSEONCOOKIEEXPIRY" ]; then
					[ -n "$VERBOSE" ] && echo -n " - waiting 2 minutes [12 dots]:"
					for (( i=1; i<=12; i++)); do sleep 10s; [ -n "$VERBOSE" ] && echo -n "."; done
					[ -n "$VERBOSE" ] && echo -n "done"
				fi
			else
				[ -n "$VERBOSE" ] && echo -n "  all login cookies are still valid"
			fi
			[ -n "$VERBOSE" ] && echo
		else
			[ -n "$VERBOSE" ] && echo "No successful login cookies found in $COOKIEJAR"
		fi
	fi
	if [ -z "$QUIET" ]; then
		[ -n "$VERBOSE" ] && echo -n "  "
		echo -en "$2"
		if [ -n "$4" ]; then
			echo -en " for credit >$4 cents"
			if [ ${#4} -lt 3 -a "$4" != "0" ]; then
				echo -e "\nError: $1 / $2 - can't check for $4 (<100 cents), please supply higher value">&2
				return 1
			fi
		fi
		echo -n ": "
	fi

	# Curl settings
	# -L --location option follows redirects, -i --include adds header information to the output file (makes debug easier)
	
	CURLOPTIONS=( "--user-agent" "\"$USERAGENT\"" "--max-time" "30" "--insecure" "--show-error" "--location" )
	#CURLOPTIONS=( "--max-time" "30" "--insecure" "--show-error" "--location" )
	[ -z "$DEBUG" ] && CURLOPTIONS+=( "--silent" ) || echo -e "\nCURLOPTIONS       : ${CURLOPTIONS[@]}"

	# Get remote login page with curl
	PAGE1="https://$1/login"
	for ((RETRIEVELOOP=1; RETRIEVELOOP<=3; RETRIEVELOOP++)); do
		[ $RETRIEVELOOP -gt 1 ] && echo -n "  try $RETRIEVELOOP/3: "
		unset EXPIRED
		curl -b "$COOKIEJAR" -c "$COOKIEJAR" "${CURLOPTIONS[@]}" --fail --include -o "$TEMP/$THIS-$(id -u)-$1-1.htm" "$PAGE1"
		CURLEXIT=$?; [ -n "$DEBUG" ] && echo "Curl exit status  : $CURLEXIT"; [ $CURLEXIT -gt 0 ] && { echo "Curl exit code $CURLEXIT, aborting...">&2; return 2; }
		[ -n "$DEBUG" ] && echo -e "Visited           : $PAGE1\nSaved as          : $TEMP/$THIS-$(id -u)-$1-1.htm\nCookies saved as  : $COOKIEJAR"
		if [ -n "`grep "$2" "$TEMP/$THIS-$(id -u)-$1-1.htm"`" ]; then
			[ -n "$DEBUG" ] && echo "We are already logged in, retrieving info from original page"
			USEFILE=1; break
		fi

		# Locate the correct version of the hidden tag (inside Ajax code, if present)
		unset LINESTART
		HIDDENTAG=$(sed -n '/show_webclient&update_id=&/{s/.*=//;s/".*/\" \//p}' "$TEMP/$THIS-$(id -u)-$1-1.htm")
		if [ -n "$HIDDENTAG" ]; then
			# this works on some portals with Firefox useragent, not with IE or Safari
			# find the form input line which contains the hiddentag
			LINEOFTAG=$(grep -n "$HIDDENTAG" "$TEMP/$THIS-$(id -u)-$1-1.htm"|awk -F: '{printf $1}')
			# find the line of the preceding start of form
			LINESTART=$(awk -v LINEOFTAG=$LINEOFTAG '{if (NR==LINEOFTAG) {printf FORMSTART; exit}; if (match($0,"<form")!=0) FORMSTART=NR}' "$TEMP/$THIS-$(id -u)-$1-1.htm")
			[ -n "$DEBUG" ] && echo -e "Hidden  Tag       : '$HIDDENTAG'\nLine of Tag       : '$LINEOFTAG'\nForm starts @ line: '$LINESTART'"
			[ -z "$LINESTART" ] && echo "An error occurred extracting start of the correct form"
		fi
		if [ -z "$LINESTART" ]; then
			# this decryption method seems to be required for voicetrading.com at least
			[ -n "$DEBUG" ] && echo -e "Unable to find correct version of hidden tag directly, using decryption"
			# extract the encrypted_string and the key
			ENC_AND_KEY=( $(sed -n '/getDecVal/{s/.*getDecValue(//;s/).*//;s/,//;s/"//gp;q}' "$TEMP/$THIS-$(id -u)-$1-1.htm") )
			[ -z "${ENC_AND_KEY[0]}" -o -z "${ENC_AND_KEY[1]}" ] && echo "Unable to extract encrypted magictag and/or key, aborting..." >&2 && return 3
			[ -n "$DEBUG" ] && echo -e "Encrypted Magictag: \"${ENC_AND_KEY[0]}\"\nKey               : \"${ENC_AND_KEY[1]}\"\nDecryption using openssl..."
			# decrypt the magictag by splitting it into 32-character lines then passing to openssl (code by Loran)
			MAGICTAG=$(echo "${ENC_AND_KEY[0]}" | sed 's/.\{32\}/&\n/g;s/\n$//' | openssl enc -d -aes-256-cbc -a -k "${ENC_AND_KEY[1]}")
			[ -z "$MAGICTAG" ] && echo "An error occurred extracting magictag, aborting...">&2 && return 4
			[ -n "$DEBUG" ] && echo -e "Decrypted Magictag: \"$MAGICTAG\""
			# get start line of the correct form i.e. div tagged with MAGICTAG
			LINESTART=$(grep -n "$MAGICTAG" "$TEMP/$THIS-$(id -u)-$1-1.htm"|awk -F: '{printf $1; exit}')
			[ -z "$LINESTART" ] && echo "An error occurred extracting start of the correct form using magic key '$MAGICTAG', aborting...">&2 && return 5
			[ -n "$DEBUG" ] && echo -e "Form starts @ line: '$LINESTART' of $TEMP/$THIS-$(id -u)-$1-1.htm"
		fi

		# extract the form info
		sed -n "1,$(( ${LINESTART} -1 ))d;p;/<\/form>/q" "$TEMP/$THIS-$(id -u)-$1-1.htm">"$TEMP/$THIS-$(id -u)-$1-3.htm"
		[ -n "$DEBUG" ] && echo -e "Form saved as     : $TEMP/$THIS-$(id -u)-$1-3.htm"
		# check for a captcha image
		CAPTCHA=$(sed -n '/id="captcha_img/{s/.*src="//;s/".*//p;q}' "$TEMP/$THIS-$(id -u)-$1-3.htm")
		unset HIDDEN
		if [ ${#CAPTCHA} -gt 100 ]; then
			echo -e "\nError extracting CAPTCHA code">&2
			return 6
		elif [ -n "$CAPTCHA" ]; then
			if [ -z "$SKIPONCAPTCHA" ]; then
				[ -n "$DEBUG" ] && echo -e "Retrieving Captcha: $CAPTCHA"
				curl -c "$COOKIEJAR" -b "$COOKIEJAR" "${CURLOPTIONS[@]}" -e "$PAGE1" --fail -o "$CAPTCHAPATH$THIS-$1-captcha.jpeg" $CAPTCHA
				CURLEXIT=$?
				[ -n "$DEBUG" ] && echo "Curl exit status  : $CURLEXIT"
				echo -e "\n  Captcha image saved as $CAPTCHAPATH$THIS-$1-captcha.jpeg"
				read -p "  Please enter Captcha code: " -t 120 </dev/stderr
				[ -z "$REPLY" ] && { echo "Skipping $1 retrieval...">&2; return 7; }
				echo -n "  "
				HIDDEN=" -F login[usercode]=\"$REPLY\""
			else
				[ -n "$QUIET" ] && echo -n "$1: "
				echo "[FAIL] - captcha code requested, try again with -c option"
				rm -f "$COOKIEJAR"
				USEFILE=0
				break
			fi
		fi
		# there are hidden fields with complicated name and data
		HIDDEN+=$(grep -o "<input type=\"hidden\"[^>]*>" "$TEMP/$THIS-$(id -u)-$1-3.htm"|awk -F \" '{for (i=1; i<NF; i++) {if ($i==" name=") printf " -F " $(i+1) "="; if ($i==" value=") printf $(i+1)}}')
		FORMRETURNPAGE=`sed -n '/<form/{s/.*action="\([^"]*\).*/\1/;p;q}' "$TEMP/$THIS-$(id -u)-$1-3.htm"`
		if [ -n "$DEBUG" ]; then
			[ -n "$HIDDEN" ] && echo -e "Hidden fields     : $HIDDEN"
			DEBUGFILE="$TEMP/$THIS-$(id -u)-$1-2d.htm"
			DEBUGCURLEXTRA=" --trace-ascii $DEBUGFILE "
		else
			unset DEBUGCURLEXTRA
		fi
		# Get the form data
		if [ -n "$FORMRETURNPAGE" ]; then
			curl -b "$COOKIEJAR" -c "$COOKIEJAR" "${CURLOPTIONS[@]}" $DEBUGCURLEXTRA -e "$PAGE1" --fail --include -F "login[username]=$2" -F "login[password]=$3" $HIDDEN  -o "$TEMP/$THIS-$(id -u)-$1-2.htm" "$FORMRETURNPAGE"
			CURLEXIT=$?; [ -n "$DEBUG" ] && echo "Curl exit status  : $CURLEXIT"; [ $CURLEXIT -gt 0 ] && { echo "Curl exit code $CURLEXIT, aborting...">&2; return 8; }
			[ -s "$TEMP/$THIS-$(id -u)-$1-2.htm" ] || { echo "Curl failed to save file $TEMP/$THIS-$(id -u)-$1-2.htm, aborting...">&2; return 9; }
			if [ -n "$DEBUG" ]; then
				sed -i "s/$3/\[hidden\]/g" "$DEBUGFILE" # remove password from debug file
				echo -e "Visited           : $FORMRETURNPAGE\nSaved as          : $(ls -l $TEMP/$THIS-$(id -u)-$1-2.htm)\nTrace-ascii output: $DEBUGFILE (password removed)"
			fi
			if [ -n "$(grep "This account has been disabled" "$TEMP/$THIS-$(id -u)-$1-2.htm")" ]; then
				echo "[FAIL] - account disabled"
				USEFILE=0; break
			fi
			EXPIRED=$(grep -o "your session.*expired" "$TEMP/$THIS-$(id -u)-$1-2.htm")
			if [ -n "$EXPIRED" ]; then
				[ -n "$DEBUG" ] && { echo "                    Session expired">&2; USEFILE=0; break; }
				echo "[FAIL] - session expired"
				rm -f "$COOKIEJAR"
				USEFILE=0
			else
				USEFILE=2; break
			fi
		else
			echo "No form data found, unable to obtain credit amount">&2
			USEFILE=0; break
		fi
	done
	# Get credit from retrieved file
	[ $USEFILE -gt 0 ] && CREDITCENTS=$(sed -n '/class="[^"]*balance"/{s/.*euro; //;s/.*\$//;s/<.*//;s/\.//;s/^0*//;p}' "$TEMP/$THIS-$(id -u)-$1-$USEFILE.htm")
	if [ -n "$DEBUG" ];then
		echo "Credit (cents)    : '$CREDITCENTS'"
	else
		# Clean up
		rm -f "$TEMP/$THIS-$(id -u)-$1-"*.htm # note COOKIEJARs are not removed, so cookies can be reused if it is rerun
		[ -z "$4" ] || [ -z "$QUIET" -a -n "$CREDITCENTS" ] && echo -n "$CREDITCENTS"
	fi
	if [ -z "$CREDITCENTS" ]; then
		echo "Error: $1 / $2 - CREDITCENTS is blank">&2
		RETURNCODE=11
	elif [ "$CREDITCENTS" -ge 0 -o "$CREDITCENTS" -lt 0 2>&- ]; then
		if [ -n "$6" -a -n "$5" ]; then
			# check for periodic (e.g. daily) change in credit
			if [ -s "$6" ]; then
				local PREVCREDIT=(`tail -n 1 "$6"`)
			else
				local PREVCREDIT=("2000-01-01 00:00 0")
			fi
			echo -e "`date +"%Y-%m-%d %T"`\t$CREDITCENTS">>"$6" 2>/dev/null || echo "Warning: unable to write to $6" >&2
			# Remove leading spaces if any, and add 10# so to make it work with credit like: "093" " 201"
			local CREDITFALL=$((10#${PREVCREDIT[2]}-10#$(echo $CREDITCENTS | sed -e 's/^[ \t]*//')))
			[ -n "$DEBUG" ] && echo -en "Previous credit   : '${PREVCREDIT[2]}' at ${PREVCREDIT[0]} ${PREVCREDIT[1]}\nCredit Reduction  : '$CREDITFALL'"
			if [ $CREDITFALL -gt $5 ]; then
				send_message "Credit Reduction Warning - $1\nThe credit on your $1 account '$2' stands at ${CREDITCENTS:0:$((${#CREDITCENTS}-2))}.${CREDITCENTS:(-2):2}, and has fallen by ${CREDITFALL:0:$((${#CREDITFALL}-2))}.${CREDITFALL:(-2):2} since ${PREVCREDIT[0]} ${PREVCREDIT[1]}."
			fi
		fi
		if [ -z "$4" ]; then
			echo
		else
			if [ "$4" != "0" ] && [ "$CREDITCENTS" -lt "$4" ]; then
				send_message "Credit Level Warning - $1\nThe credit on your $1 account '$2' stands at ${CREDITCENTS:0:$((${#CREDITCENTS}-2))}.${CREDITCENTS:(-2):2} - below your specified test level of ${4:0:$((${#4}-2))}.${4:(-2):2}.\nYou can buy more credit at: http://$1/myaccount/"
			elif [ -z "$QUIET" ]; then
				echo  " - ok"
			fi
		fi
		RETURNCODE=0
	else
		echo "Error: $1 / $2 - CREDITCENTS is a non-integer value: '$CREDITCENTS'">&2
		RETURNCODE=13
	fi
	shift 999
	return $RETURNCODE
}

# Start of main script

# Global variables
THIS="`basename $0`"; COLUMNS=$(stty size 2>/dev/null||echo 80); COLUMNS=${COLUMNS##* }

# Check whether script is run as CGI
if [ -n "$SERVER_SOFTWARE" ]; then
	# if being called by CGI, set the content type
	echo -e "Content-type: text/plain\n"
	# extract any options
	OPTS=$(echo "$QUERY_STRING"|sed -n '/options=/{s/.*options=\([^&]*\).*/\1/;s/%20/ /;p}')
	#echo -e "QUERY_STRING: '$QUERY_STRING'\nOPTS: '$OPTS'"
	SKIPONCAPTCHA="y" # for now we have no way to show captcha images when called from CGI script, so prevent it happening...
fi

# Parse commandline switches
while getopts ":dc:f:hlm:npqsvw" optname $@$OPTS; do
	case "$optname" in
		"c")	CAPTCHAPATH="$OPTARG";;
		"d")	DEBUG="y";VERBOSE="y";;
		"f")	CONFFILE="$OPTARG";;
		"h")	HELP="y";;
		"l")	CHANGELOG="y";;
		"m")	EMAIL="$OPTARG";;
		"n")	NEWCOOKIEJAR="y";;
		"p")	PAUSEONCOOKIEEXPIRY="y";;
		"q")	QUIET="y";;
		"s")	SKIPONCAPTCHA="y";;
		"v")	VERBOSE="y";;
		"w")	COLUMNS=30000;; #suppress line-breaking
		"?")	echo "Unknown option $OPTARG"; exit 1;;
		":")	echo "No argument value for option $OPTARG"; exit 1;;
		*)	# Should not occur
			echo "Unknown error while processing options"; exit 1;;
	esac
done

shift $(($OPTIND-1))

# Show debug info
[ -n "$DEBUG" -a -n "$QUERY_STRING" ] && echo -e "QUERY_STRING: '$QUERY_STRING'\nOPTS: '$OPTS'"

# Show author information
AUTHORSTRING="$THIS v$VERSION by Dominic"
[ -z "$QUIET" -o -n "$HELP$CHANGELOG" ] && echo -e "\n$AUTHORSTRING\n${AUTHORSTRING//?/=}"

# Show help
if [ -n "$HELP" ]; then
	echo -e "\nGNU/Linux program to notify if credit on one or more \
Dellmont/Finarea/Betamax voip \
provider accounts is running low. Once successfully tested it can be run \
as daily cron job with -q option and -m email_address option \
so that an email is generated when action to top up \
credit on the account is required. Can also run under MS Windows using Cygwin \
(http://www.cygwin.com/), or can be run as CGI job on Linux/Apache webserver.

Usage: `basename $0` [option]

Conffile:
A conffile should be in the same directory as $THIS with name \
$(basename $THIS .sh).conf, or if elsewhere or differently named then be specified by option -f, and should contain one or more lines giving the \
Dellmont/Finarea/Betamax account details in the form:

website username password [test_credit_level_in_cents] [credit_reduction_in_cents] [credit_recordfile]

where the test_credit_level_in_cents is >=100 or 0 (0 means 'never send \
email'). If you don't specify a test_credit_level_in_cents then the \
current credit level is always displayed (but no email is ever sent).

If you specify them, the credit_reduction and credit_recordfile work together \
to perform an additional test. The program will record in credit_recordfile \
the amount of credit for the given portal each time it is run, and notify you \
if the credit has reduced since the last time by more than the \
credit_reduction. This can be useful to warn you of unusual activity on \
the account or of a change in tariffs that is significant for you. \
Set the credit_reduction_in_cents to a level that is more than you \
would expect to see consumed between consecutive (e.g. daily) runs of $THIS \
e.g. 2000 (for 20 euros/day or 20 dollars/day).

Here's an example single-line conffile to generate a warning \
email if the credit \
on the www.voipdiscount.com account falls below 3 euros (or dollars):
www.voipdiscount.com myaccount mypassword 300

Temporary_Files:
Temporary files are saved with 600 permissions in \$TEMP which is set to a \
standard location, normally /tmp, unless it is already defined (so you can \
define it if you want a special location). Unless run with debug option, \
all such files are deleted after running - except the cookiejar file which \
is retained so it can be reused. (The same cookiejar file is also used, if \
found, by get-vt-cdrs.sh.)

CGI_Usage:
Here is an example of how you could use $THIS on your own (presumably \
internal) website (with CGI configured appropriately on your webserver):
http://www.mywebsite.com/$THIS?options=-vf%20/path/to/my_conf_file.conf%20-m%20me@mymailaddress.com

Options:
  -c [path] - save captcha images (if any) at path (default is current path)
  -d  debug - be very verbose and retain temporary files
  -f [path/conffile] - path and name of conffile
  -h  show this help and exit
  -l  show changelog and exit
  -m [emailaddress] - send any messages about low credit or too-rapidly-falling credit to the specified address (assumes sendmail is available and working)
  -n  delete any existing cookies and start over
  -p  pause on cookie expiry - wait 2 minutes if cookies have expired before \
trying to login (because cookies are usually for 24 hours exactly this should \
allow a second login 24 hours later without requiring new cookies)
  -q  quiet
  -s  skip if captcha code is requested (e.g. for unattended process)
  -v  be more verbose

Dependencies: awk, bash, coreutils, curl, grep, openssl, sed, [sendmail], umask

License: Copyright 2016 Dominic Raferd. Licensed under the Apache License, \
Version 2.0 (the \"License\"); you may not use this file except in compliance \
with the License. You may obtain a copy of the License at \
http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable \
law or agreed to in writing, software distributed under the License is \
distributed on an \"AS IS\" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY \
KIND, either express or implied. See the License for the specific language \
governing permissions and limitations under the License.

Portal List:
Here is a list of websites / sip portals belonging to and/or operated by \
Dellmont. To find more, google &quot;is a service from dellmont sarl&quot; \
(with the quotes). Try a portal with $THIS - it might work!

If one of these (or \
another which you know is run by Dellmont) does not work, run $THIS with -d \
option and drop me an email attaching the temporary files (two or three \
per portal, password is stripped out anyway).

http://www.12voip.com
http://www.actionvoip.com
http://www.aptvoip.com
http://www.bestvoipreselling.com
http://www.calleasy.com
http://www.callingcredit.com
http://www.cheapbuzzer.com
http://www.cheapvoip.com
http://www.companycalling.com
http://www.cosmovoip.com
http://www.dialcheap.com
http://www.dialnow.com
http://www.easycallback.com
http://www.easyvoip.com
http://www.freecall.com
http://www.freevoipdeal.com
http://www.frynga.com
http://www.hotvoip.com
http://www.internetcalls.com
http://www.intervoip.com
http://www.jumblo.com
http://www.justvoip.com
http://www.lowratevoip.com
http://www.megavoip.com
http://www.netappel.fr
http://www.nonoh.net
http://www.pennyconnect.com
http://www.poivy.com
http://www.powervoip.com
http://www.rebvoice.com
http://www.rynga.com
http://www.scydo.com
http://www.sipdiscount.com
http://www.smartvoip.com
http://www.smsdiscount.com
http://www.smslisto.com
http://www.stuntcalls.com
http://www.supervoip.com
http://www.telbo.ru
http://www.voicetrading.com
http://www.voicetel.co
http://www.voipblast.com
http://www.voipblazer.com
http://www.voipbuster.com
http://www.voipbusterpro.com
http://www.voipcheap.co.uk
http://www.voipcheap.com
http://www.voipdiscount.com
http://www.voipgain.com
http://www.voipmove.com
http://www.voippro.com
http://www.voipraider.com
http://www.voipsmash.com
http://www.voipstunt.com
http://www.voipwise.com
http://www.voipzoom.com
http://www.webcalldirect.com

A page showing relative prices for many of these sites can be found at http://backsla.sh/betamax.
"|fold -s -w $COLUMNS
fi

# Show changelog
if [ -n "$CHANGELOG" ]; then
	[ -n "$HELP" ] && echo "Changelog:" || echo
	echo "\
4.4.1 [29 Jun 2016]: rename cookiejar and temporary files to include userid (number) rather than username
4.4.0 [25 Mar 2016]: bugfix
4.3.9 [16 Mar 2016]: bugfix
4.3.8 [15 Mar 2016]: set permissions of all files created to 600, to secure from other users, move cookiejar files back to \$TEMP and rename cookiejar filename to include \$USER so that multiple users do not overwrite one another's cookiejars
4.3.7 [19 Feb 2016]: if the specified credit_recordfile can't be accessed, show warning instead of failing
4.3.6 [08 Feb 2016]: bugfix for credit <100 eurocents
4.3.5 [18 May 2015]: move cookiejar file location to /var/tmp
4.3.4 [01 Oct 2014]: minor bugfix
4.3.3 [06 Sep 2014]: allow checking of multiple accounts for same provider
4.3.2 [05 Sep 2014]: improvements to debug text and error output
4.3.1 [23 Jul 2014]: warning message if no lines found in conf file
4.3.0 [28 Nov 2013]: use local openssl for decryption (when \
required) instead of remote web call (thanks Loran)
4.2.0 [03 Nov 2013]: a lot of changes! Enable CGI usage, remove \
command-line setting of conffile and email and instead specify these by -f \
and -m options. Test_credit_level_in_cents is now optional in conffile. Add \
-v (verbose) option. Squash a bug causing failure if a captcha was requested.
4.1.1 [01 Nov 2013]: select the reported 'user-agent' randomly from a few
4.1.0 [01 Nov 2013]: local solution is tried before relying on remote \
decryption call (thanks Loran)
4.0.5 [01 Nov 2013]: fix for low-balance or $ currency
4.0.1 [30 Oct 2013]: fix magictag decryption
4.0.0 [29 Oct 2013]: works again, requires an additional decryption web call \
- note a change to conf file format
3.6 [21 Oct 2013]: works sometimes...
3.5 [04 Oct 2013]: small tweaks but more reliable I think...
3.4 [03 Oct 2013]: retrieves captcha image but still not reliable :(
3.3 [29 Sep 2013]: correction for new credit display code
3.2 [18 Sep 2013]: corrected for new login procedure
3.1 [10 Oct 2012]: minor text improvements
3.0 [27 Aug 2012]: minor text correction for credit reduction
2.9 [16 Aug 2012]: added optional credit reduction notification
2.8 [27 Jun 2012]: now works with www.cheapbuzzer.com, added \
a list of untested Dellmont websites to the help information
2.7 [25 May 2012]: now works with www.webcalldirect.com
2.6 [25 May 2012]: fix to show correct credit amounts if >=1000
2.5 [15 May 2012]: fix for added hidden field on voipdiscount.com
2.4 [10 May 2012]: improved debug information, voicetrading.com \
uses method 2, rename previously-named fincheck.sh as \
dellmont-credit-checker.sh
2.3 [04 May 2012]: improved debug information
2.2 [03 May 2012]: further bugfixes
2.1 [03 May 2012]: now works with www.voipbuster.com
2.0315 [15 Mar 2012]: allow comment lines (beginning with \
hash #) in conffile
2.0313 [13 Mar 2012]: changes to email and help text and \
changelog layout, and better removal of temporary files
2.0312 [10 Mar 2012]: improve help, add -l changelog option, remove \
deprecated methods, add -d debug option, tidy up temporary files, \
use conffile instead of embedding account data directly in \
script, first public release
2.0207 [07 Feb 2012]: new code uses curl for voipdiscount.com
2.0103 [03 Jan 2012]: no longer uses finchecker.php or fincheck.php \
unless you select \
deprecated method; has 2 different approaches, one currently works for \
voipdiscount, the other for voicetrading.
1.3 [21 Jun 2010]: stop using external betamax.sh, now uses external \
fincheck.php via finchecker.php, from \
http://simong.net/finarea/, using fincheck.phps for fincheck.php; \
finchecker.php is adapted from example.phps
1.2 [03 Dec 2008]: uses external betamax.sh script
1.1 [17 May 2007]: allow the warning_credit_level_in_euros to be set separately on \
each call
1.0 [05 Jan 2007]: written by Dominic, it is short and sweet and it works!
"|fold -sw $COLUMNS
fi

# Exit if help or changelog was asked
[ -n "$HELP$CHANGELOG" ] && exit

# Show debug info
[ -n "$DEBUG" ] && echo -e "Debug mode"

# Ensure that all files created are readable/writeable only by current user
umask 177	

# Check for conffile 
if [ -z "$CONFFILE" ]; then
	[ ! -s "$1" ] && CONFFILE="$(echo "$(dirname "$0")/$(basename "$0" .sh).conf")"  || CONFFILE="$1"
fi
[ -n "$DEBUG" ] && echo "CONFFILE: '$CONFFILE'"
[ ! -s "$CONFFILE" ] && echo "Cannot find conf file '$1', aborting">&2 && exit 1

# Print email adress
[ -n "$EMAIL" -a -z "$QUIET" ] && echo -e "Any low credit warnings will be emailed to $EMAIL\n"

# Ensure CAPTCHAPATH ends with a slash, and that the path exists
if [ -n "$CAPTCHAPATH" ];then
	if [ "${CAPTCHAPATH:$(( ${#CAPTCHAPATH} - 1 )): 1}" != "/" ]; then
		CAPTCHAPATH="${CAPTCHAPATH}/"
		[ -n "$DEBUG" ] && echo "CAPTCHAPATH amended to: '$CAPTCHAPATH'"
	fi
	[ -d "$CAPTCHAPATH" ] || { echo "Could not find path '$CAPTCHAPATH', aborting...">&2; exit 1; }
fi

# Select (fake) user agent from a few possibles (http://www.useragentstring.com/pages/useragentstring.php?name=Firefox)
# Do not use Safari and IE because with them we never get the embedded hiddentag
USERAGENT[0]="Mozilla/5.0 (Windows NT 6.1; WOW64; rv:40.0) Gecko/20100101 Firefox/40.1"
USERAGENT[1]="Mozilla/5.0 (Windows NT 6.3; rv:36.0) Gecko/20100101 Firefox/36.0"
USERAGENT[2]="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10; rv:33.0) Gecko/20100101 Firefox/33.0"
USERAGENT[3]="Mozilla/5.0 (X11; Linux i586; rv:31.0) Gecko/20100101 Firefox/31.0"
USERAGENT[4]="Mozilla/5.0 (Windows NT 6.1; WOW64; rv:31.0) Gecko/20130401 Firefox/31.0"
USERAGENT[5]="Mozilla/5.0 (Windows NT 5.1; rv:31.0) Gecko/20100101 Firefox/31.0"
USERAGENT[6]="Mozilla/5.0 (Windows NT 6.1; WOW64; rv:29.0) Gecko/20120101 Firefox/29.0"
USERAGENT[7]="Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:25.0) Gecko/20100101 Firefox/29.0"
USERAGENT[8]="Mozilla/5.0 (X11; OpenBSD amd64; rv:28.0) Gecko/20100101 Firefox/28.0"
USERAGENT[9]="Mozilla/5.0 (X11; Linux x86_64; rv:28.0) Gecko/20100101 Firefox/28.0"
USERAGENT[10]="Mozilla/5.0 (Windows NT 6.1; rv:27.3) Gecko/20130101 Firefox/27.3"
USERAGENT[11]="Mozilla/5.0 (Windows NT 6.2; Win64; x64; rv:27.0) Gecko/20121011 Firefox/27.0"
USERAGENT[12]="Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:25.0) Gecko/20100101 Firefox/25.0"
USERAGENT[13]="Mozilla/5.0 (Macintosh; Intel Mac OS X 10.6; rv:25.0) Gecko/20100101 Firefox/25.0"
USERAGENT="${USERAGENT[$(($RANDOM%${#USERAGENT[@]}))]}"
[ -n "$DEBUG" ] && echo "Selected user agent: \"$USERAGENT\""

# Loop through conffile line by line
LINENUM=0; ERRS=0
while read LINE; do
	let LINENUM++
	[ -n "$DEBUG" ] && { echo -n "conffile line $LINENUM   :"; echo "$LINE"|awk '{printf $1 " " $2 "..." }'; }
	if [ -n "$LINE" -a "${LINE:0:1}" != "#" ]; then
		[ -n "$DEBUG" ] && echo -n " - checking"
		check_credit_level $LINE; CERR=$?
		[ $CERR -eq 0 ] || { let ERRS++; echo -n " Error $CERR occurred for "; echo "$LINE"|awk '{print $1 " " $2 }'; }
	elif [ -n "$DEBUG" ]; then
		echo " - skipping"
	fi
	[ -n "$DEBUG" ] && echo
done<"$CONFFILE"
[ $LINENUM -eq 0 ] && echo "Could not find any lines in $CONFFILE to process, did you miss putting an EOL?" >&2
[ -n "$DEBUG" ] && echo "Completed with ERRS: '$ERRS'"
exit $ERRS
