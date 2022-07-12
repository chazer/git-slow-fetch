#!/usr/bin/env bash

set +o pipefail

pktline() {
	local LEN;
	LEN="$( echo -n "____$1_" | wc -c )"
	printf "%04x%s\n" "$LEN" "$1"
}

reqend() {
	printf "0000"
}

HEAD="$HEAD""
BASE="$BASE"
REPO="$REPO?:need a repo in REPO env"

# Check commit on local object db
# Return type (commin/blob/tree) if object exists
# empty result and code 128 if no object
db_get_object_type() {
	git cat-file -t "$1" 2>/dev/null
}

db_find_commits() {
	git cat-file --batch-check='%(objecttype) %(objectname)' --batch-all-objects | grep '^commit ' | sed 's/^commit //'
}

print_object_info() {
	local OTYPE="$( db_get_object_type "$1" )" || return 1
	echo "type: $OTYPE"
	echo "size: $( git cat-file -s "$1" 2>/dev/null )"
	if [ "$OTYPE" = "commit" -o "$OTYPE" = "tree" ]; then
		git cat-file -p "$1" 2>/dev/null
	fi
}

if [ "$1" = "print-object" ]; then
	shift
	print_object_info "$@"
	exit $?
fi

commit_get_parent() {
	local OTYPE
	OTYPE="$( db_get_object_type "$1" )" || return 1
	[ "$OTYPE" = "commit" ] || return 2
	git cat-file -p "$1" | grep '^parent ' | sed 's/^parent //'
}

if [ "$1" = "commit-get-parent" ]; then
	shift
	commit_get_parent "$@"
	exit $?
fi

commit_get_tree() {
	local OTYPE
	OTYPE="$( db_get_object_type "$1" )" || return 1
	[ "$OTYPE" = "commit" ] || return 2
	git cat-file -p "$1" 2>/dev/null | grep '^tree ' | sed 's/^tree //'
}

if [ "$1" = "commit-get-tree" ]; then
	shift
	commit_get_tree "$@"
	exit $?
fi

__print_tree_object_content() {
	local filter="$3"
	local OTYPE="$( db_get_object_type "$1" )" || return 1
	[ "$OTYPE" = "tree" ] || return 2
	git cat-file -p "$1" 2>/dev/null | while read -r f a b c; do
		local EX=" "
		db_get_object_type "$b" >/dev/null && EX="+"
		if [ "$a" = "blob" ]; then
			[ "$filter" = "" -o "$filter" = "blob" ] && echo  "[$EX]" "$f $a $b $2$c"
			continue
		fi
		if [ "$a" = "tree" ]; then
			[ "$filter" = "" -o "$filter" = "tree" ] && echo "[$EX]" "$f $a $b $2$c/"
			[ "$EX" = "+" ] && __print_tree_object_content "$b" "$2$c/" "$filter" || return 1
			continue
		fi
		[ "$filter" = "" ] && echo "$a" "$b" "$2$c"
	done
}

__scan_tree_with_file() {
	local OID="$1"
	local prefix="$2"
	local file="$4"
	#local OTYPE="$( db_get_object_type "$1" )" || return 1
	#[ "$OTYPE" = "tree" ] || return 2
	git cat-file -p "$OID" 2>/dev/null | while read -r f t h n; do
		#echo "... $f $t $h $prefix/$n" >&2
		if [ "$file" -a -f "$file" ] && grep -q '^\[F\] '"$f $t $h" "$file"; then
			echo "[F] $f $t $h $prefix$n"
			continue
		fi
		local EX="_"; db_get_object_type "$h" >/dev/null && EX="+"
		if [ "$t" = "blob" ]; then
			echo  "[$EX]" "$f $t $h $prefix$n"
			continue
		fi
		if [ "$t" = "tree" ]; then
			if [ "$EX" = "+" ]; then
				local subtree
				subtree="$( __scan_tree_with_file "$h" "$prefix$n/" "" "$file" )" || return $?
				if ! echo "$subtree" | grep -q '^\[[_ ]\]'; then
					echo "[F] $f $t $h $prefix$n/"
				else
					echo "[+] $f $t $h $prefix$n/"
					echo "$subtree"
				fi
				continue
			fi
			echo "[$EX]" "$f $t $h $prefix$n/"
			continue
		fi
		echo "$t" "$h" "$prefix$n"
	done
}


__tree_print_unexists_tree_objects() {
	local OID="$1"
	git cat-file -p "$OID" 2>/dev/null | while read -r f a b c; do
		local EX=" "
		db_get_object_type "$b" >/dev/null && EX="+"
		if [ "$a" = "tree" ]; then
			if [ "$EX" = "+" ]; then
				__tree_print_unexists_tree_objects "$b" "$2$c/" || return 1
			else
				echo "[$EX]" "$f $a $b $2$c/" >&2
				echo "$b"
			fi
			continue
		fi
	done
}

object_scan_content() {
	local OID="$1"
	local OTYPE
	OTYPE="$( db_get_object_type "$OID" )" || return 1
	if [ "$OTYPE" = "commit" ]; then
		OID="$( commit_get_tree "$OID" )" || return 3
		OTYPE="$( db_get_object_type "$OID" )" || return 1
	fi
	[ "$OTYPE" = "tree" ] || return 2
	__print_tree_object_content "$OID"
}

if [ "$1" = "object-scan-content" ]; then
	shift
	object_scan_content "$@"
	exit $?
fi

object_scan_with_file() {
	local OID="$1"
	local file="$2"
	local OTYPE
	OTYPE="$( db_get_object_type "$OID" )" || return 1
	if [ "$OTYPE" = "commit" ]; then
		OID="$( commit_get_tree "$OID" )" || return 3
		OTYPE="$( db_get_object_type "$OID" )" || return 1
	fi
	[ "$OTYPE" = "tree" ] || return 2
	local new_file_content
	__scan_tree_with_file "$OID" "" "" "$file" | {
		local new_file="$( mktemp )"
		tee "$new_file";
		cat "$new_file" > "$file" || true;
		rm "$new_file" || true;
	}
}

if [ "$1" = "object-scan-with-file" ]; then
	shift
	object_scan_with_file "$@"
	exit $?
fi

commit_scan_trees() {
	local tree
	tree="$( commit_get_tree "$1" )"
	if [ $? -ne 0 ]; then
		return 1
	fi
	__print_tree_object_content "$tree" "" "tree"
}

if [ "$1" = "commit-scan-trees" ]; then
	shift
	commit_scan_trees "$@"
	exit $?
fi

print_commit_status() {
	local CONTENT
	CONTENT="$( print_commit_content "$1" )"
	if [ $? -ne 0 ]; then
		echo 0
		return 1
	fi
	local done
	local none
	done="$( echo "$CONTENT" | grep '^\[+\]' | wc -l )"
	none="$( echo "$CONTENT" | grep '^\[ \]' | wc -l )"
	echo "$CONTENT" >&2
	if [ $done = 0 -a $none = 0 ]; then
		echo "0 / 0 = 0%" >&2
		echo 0
	else
		echo "$done / $(( $done + $none )) = $(( 100 * $done / ( $done + $none ) ))%" >&2 
		echo "$(( 100 * $done / ( $done + $none ) ))%" 
	fi
	return 0
}

if [ "$1" = "print-commit-status" ]; then
	shift
	print_commit_status "$@"
	exit $?
fi

fetch_commit_pack() {
	echo "FETCH $1..$2" >&2
	{
	#pktline 'want 1234567812345678123456781234567812345678 multi_ack_detailed no-done side-band-64k thin-pack ofs-delta deepen-since deepen-not agent=git/2.30.2';
	pktline 'want '"$1"' multi_ack_detailed no-done thin-pack ofs-delta deepen-since deepen-not agent=git/2.30.2';
	while [ "$1" ]; do
		pktline 'want '"$1";
		shift;
	done
	#if [ "$2" ]; then
	#	pktline 'shallow '"$2";
	#fi
	#pktline 'deepen-not '"$2";
	#commit_get_done_objects "$1" | while read -r n; do pktline "have $n"; done
	#pktline 'filter blob:none';
	reqend;
	pktline 'done';
	} | \
	curl --url "$REPO"'/git-upload-pack' \
	--data-binary @- \
	-H 'user-agent: git/2.30.2' \
	-H 'accept-encoding: deflate, gzip, br' \
	-H 'content-type: application/x-git-upload-pack-request' \
	-H 'accept: application/x-git-upload-pack-result' \
	--output - 2>/dev/null | { read -N 8 TAG; cat; }
}

if [ "$1" = "fetch-commit-pack" ]; then
	shift
	fetch_commit_pack "$@"
	exit $?
fi

continue_commit_download() {
	local OID="$1"
	local OTYPE
	OTYPE="$( db_get_object_type "$OID" )" || {
		echo "No object found $OID" >&2;
		return 1;
	}
	if [ "$OTYPE" = "commit" ]; then
		OID="$( commit_get_tree "$OID" )"
		OTYPE="$( db_get_object_type "$OID" )"
	fi
	[ "$OTYPE" = "tree" ] || {
		echo "Object $OID is $OTYPE. Expected tree" >&2;
		return 2;
	}
	echo "Scan commit for uncomplete tree objects" >&2
	local OBJECTS
	OBJECTS="$( __tree_print_unexists_tree_objects "$OID" )" || return 1
	for n in $OBJECTS; do
		echo "Download object $n"
		fetch_commit_pack | git unpack-objects
	done
}

if [ "$1" = "continue-commit-download" ]; then
	shift
	continue_commit_download "$@"
	exit $?
fi

progress() {
	dd status=progress
}

dl_set_mark() {
	local hash="$1"
	local mark="$2"
	local file="$3"
	sed 's/^\[.\] \(.* '"$hash"' \)/['"$mark"'] \1/' -i "$file"
}

dl_refresh_file() {
	local commit="$1"
	local file="$2"
	echo "Refresh commit dump file $file" >&2
	object_scan_content "$commit" | progress > "$file" || return $?
	echo "Done commit scan process" >&2
}

dl_find_unexists_trees() {
	local file="$1"
	grep '^\[ \] [0-9]\+ tree ' < "$file" | awk '{print $5}'
}

dl_find_unexists_objects() {
	local file="$1"
	grep '^\[ \] [0-9]\+ tree ' < "$file" | awk '{print $5}'
	grep '^\[ \] [0-9]\+ blob ' < "$file" | awk '{print $5}'
}

__dl_fetch_objects_from_pipe() {
	local file="$1"
	echo "dl_fetch_objects $1" >&2
	xargs -L 1 </dev/stdin | while read -r list; do
		local count="$( echo "$list" | wc -w )"
		echo "fetch pack with $count objects" >&2
		fetch_commit_pack $list | git unpack-objects
		if [ $? -gt 0 ]; then
			echo "some errors on fetch or unpack" >&2
		fi
		for OID in $list; do
			local OTYPE
			OTYPE="$( db_get_object_type "$OID" )" || {
				echo "no object found $OID" >&2;
				continue;
			}
			if [ "$OTYPE" = "blob" ]; then
				echo mark blob "$OID done" >&2
				dl_set_mark "$OID" "+" "$file" || echo "error on mark blob $OID" >&2
				continue
			fi
			if [ "$OTYPE" = "tree" ]; then
				object_scan_content "$OID" >> "$file" || {
					echo "error on scan new tree object $OID" >&2;
					continue;
				}
				echo mark tree "$OID done" >&2
				dl_set_mark "$OID" "+" "$file" || echo "error on mark tree $OID" >&2
				continue
			fi
		done
	done
}

dl_fetch_objects() {
	local commit="$1"
	local file="$( mktemp )"
	local objects
	while true; do
		dl_refresh_file "$commit" "$file" || return $?
		objects="$( dl_find_unexists_trees "$file" )"
		local count="$( echo "$objects" | wc -w )"
		echo "found $count unexists tree objects" >&2
		if [ $count -eq 0 ]; then
			break
		fi
		echo "$objects" | __dl_fetch_objects_from_pipe "$file"
		echo "next round of tree fetching" >&2
	done
}

if [ "$1" = "fix-commit" ]; then
	shift
	dl_fetch_objects "$@"
	exit $?
fi


main() {
	local commit="$1"
	[ "$commit" ] || return 1
	while true; do
		local OTYPE
		OTYPE="$( get_object_type "$commit" )" || true
		if [ $? -gt 0 ]; then
			# no commit, download it
			fetch_commit_pack "$commit" | git unpack-objects
			if [ $? -gt 0 ]; then
				echo "Error on fetch full chain for $commit" >&2
			fi
			OTYPE="$( get_object_type "$commit" )" || true
		fi
		if [ "$OTYPE" = "" ]; then
			echo "Can't find commit $commit" >&2
			return 1
		fi
		if [ ! "$OTYPE" = "commit" ]; then
		       echo "Object $commit is $OTYPE. Commit expected" >&2
		fi	       
		echo "======"
		echo "\tcommit: $commit" >&2
		print_object_info "$commit" >&2
		local parent
		parent="$( db_get_commit_parent_oid "$commit" )" || true
		echo "\tparent: $parent" >&2
		local progress
		progress="$( print_commit_status "$commit" )"
		echo "\tprogress: $progress %" >&2
		if [ "$progress" = "100" ]; then
			commit="$parent"
			if [ ! "$parent" ]; then
				echo "Done. No more commits" >&2
				break;
			fi
			echo "Commit download is done. Go to next $commit" >&2
			continue
		fi
		continue_commit_download "$commit"
		echo "Re-check commit status" >&2
	done
}

main $HEAD
exit 0


{
#pktline 'want 1234567812345678123456781234567812345678 multi_ack_detailed no-done side-band-64k thin-pack ofs-delta deepen-since deepen-not agent=git/2.30.2';
pktline 'want 1234567812345678123456781234567812345678 multi_ack_detailed no-done thin-pack ofs-delta deepen-since deepen-not agent=git/2.30.2';
pktline 'want 1234567812345678123456781234567812345678';
#pktline 'shallow 1234567812345678123456781234567812345678';
pktline 'shallow 1234567812345678123456781234567812345678';
#git cat-file --batch-check='%(objectname)' --batch-all-objects | grep -v 1234567812345678123456781234567812345678 | while read -r n; do pktline "have $n"; done
reqend;
pktline 'done';
} | \
curl -v -X POST --url "$REPO"'/git-upload-pack' \
	--data-binary @- \
	-H 'user-agent: git/2.30.2' \
	-H 'accept-encoding: deflate, gzip, br' \
	-H 'content-type: application/x-git-upload-pack-request' \
	-H 'accept: application/x-git-upload-pack-result' \
	--output - > 1234567812345678123456781234567812345678-1234567812345678123456781234567812345678.pack
