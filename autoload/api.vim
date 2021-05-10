" Jira API functions ------------------------
let s:atlassian_url = "https://exonar.atlassian.net/rest/api/2"
let s:agile_url = "https://exonar.atlassian.net/rest/agile/1.0"

let s:jobid = -1

function s:jira_curl(callback, url, ...) abort
	if a:url =~? '^https\?://'
		let full_url = a:url
	else
		let full_url = s:atlassian_url . a:url
	endif

	let full_cmd = [
		\ "curl",
		\ "--user", utils#get_username() . ":" . utils#get_password(),
		\ "--header", "Content-Type: application/json",
		\ "--header", "Accept: application/json",
		\ "--silent",
		\ "--compressed",
		\ ] + [full_url] + a:000

	function! s:esc_cmd_for_print(arg) abort
		if a:arg =~? '^[a-zA-Z_-]\+$'
			return a:arg
		endif
		return "'" . substitute(a:arg, "'", "\\\\'", "g") . "'"
	endfunction

	" echo join(map(copy(full_cmd), {k,v -> s:esc_cmd_for_print(v)}), " ")
	let a:callback.stdout_buffered = 1

	if s:jobid > 0 && jobwait([s:jobid], 0)[0] == -1 " job still running
		call jobstop(s:jobid)
	endif

	let s:jobid = jobstart(full_cmd, a:callback)
	return s:jobid
endfunction

function s:try_to_decode_json(callback, data) abort
	if empty(a:data) || (len(a:data) == 1 && empty(a:data[0]))
		return
	endif
	try
		let data = json_decode(a:data)
	catch
		return
	endtry
	return call(a:callback, [data])
endfunction

function s:jira_curl_json(callback, url, ...) abort
	return call("s:jira_curl", [
		\ {"on_stdout": {j, data, e -> s:try_to_decode_json(a:callback, data)}},
		\ a:url,
	\ ] + a:000)
endfunction

function s:write_cache_and_callback(callback, filename, data) abort
	if empty(a:data)
		return
	endif
	call writefile([json_encode(a:data)], a:filename, "S")
	call call(a:callback, [a:data])
endfunction

function s:curl_cache(callback, url, filename, reload) abort
	let file_path = utils#cache_file(a:filename)
	if a:reload
		\ || ! filereadable(file_path)
		\ || getftime(file_path) < localtime() - 60 * 60 * 2
		\ || getfsize(file_path) < 100

		return s:jira_curl_json(
			\ {data -> s:write_cache_and_callback(a:callback, file_path, data)},
			\ a:url,
		\ )
	else
		call call(a:callback, [json_decode(readfile(file_path))])
		return -1
	endif
endfunction

" GET functions

function api#get_myself(callback) abort
	return s:jira_curl_json(a:callback, "/myself")
endfunction

function api#search(callback, query) abort
	let full_query = json_encode({
		\ "jql": a:query,
		\ "maxResults": 100,
		\ "fields": [
			\ "assignee",
			\ "customfield_10005",
			\ "issuetype",
			\ "status",
			\ "summary",
		\ ],
	\ })

	return s:jira_curl_json(a:callback, "/search", "--data", full_query)
endfunction

function api#get_issue(callback, key, reload) abort
	let fields = join([
		\ "assignee",
		\ "author",
		\ "changelog",
		\ "comment",
		\ "created",
		\ "creator",
		\ "customfield_10005",
		\ "description",
		\ "fixVersions",
		\ "issuelinks",
		\ "issuetype",
		\ "parent",
		\ "reporter",
		\ "status",
		\ "summary",
		\ "updated",
		\ "watches",
	\ ], ",")

	let url = "/issue/" . a:key . "?fields=" . fields . "&expand=changelog"
	return s:curl_cache(a:callback, url, a:key . ".json", a:reload)
endfunction

function api#get_boards(callback) abort
	return s:curl_cache(a:callback, s:agile_url . "/board", "boards.json", 0)
endfunction

function api#get_sprints(callback, board_id) abort
	let url = s:agile_url . "/board/" . a:board_id . "/sprint?state=future,active"
	let fname = "sprints-" . a:board_id . ".json"
	call s:curl_cache(a:callback, url, fname, 0)
endfunction

function api#get_create_metadata(callback, project) abort
	let url ="/issue/createmeta?projectKeys=" . a:project . "&expand=projects.issuetypes.fields"
	let fname = "createmeta-" . a:project . ".json"
	call s:curl_cache(a:callback, url, fname, 0)
endfunction

function api#get_watchers(callback, key) abort
	call s:jira_curl_json(a:callback, "/issue/" . a:key . "/watchers")
endfunction

function api#get_link_types(callback) abort
	call s:curl_cache(a:callback, "/issueLinkType", "link-types.json", 0)
endfunction

function api#get_issue_edit_metadata(callback, key) abort
	call s:jira_curl_json(a:callback, "/issue/" . a:key . "/editmeta")
endfunction

function api#get_epics(callback, board_id) abort
	let url = s:agile_url . "/board/" . a:board_id . "/epic"
	let fname = "epics-" . a:board_id . ".json"
	call s:curl_cache(a:callback, url, fname, 0)
endfunction

function api#get_transitions(callback, key) abort
	call s:jira_curl_json(a:callback, "/issue/" . a:key . "/transitions")
endfunction

" PUT functions

function api#claim_issue(callback, key) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key . "/assignee",
		\ "--request", "PUT",
		\ "--data", json_encode({"accountId": utils#get_account_id()}),
	\ )
endfunction

function api#assign_issue_to_sprint(callback, key, sprint_id) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key,
		\ "--request", "PUT",
		\ "--data", json_encode({
			\ "update": {
				\ "customfield_10005": [
					\ {
						\ "set": a:sprint_id
					\ }
				\ ]
			\ }
		\ }),
	\ )
endfunction

function api#set_issue_type(callback, key, new_type) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key,
		\ "--request", "PUT",
		\ "--data", json_encode({
			\ "fields": {
				\ "issuetype": {
					\ "id": a:new_type
				\ }
			\ }
		\ }),
	\ )
endfunction

" POST functions

function api#transition_issue(callback, key, to_state) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key . "/transitions",
		\ "--data", json_encode({"transition": {"id": a:to_state}}),
	\ )
endfunction

function api#watch_issue(callback, key) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key . "/watchers",
		\ "--request", "POST",
	\ )
endfunction

function api#comment_on_issue(callback, key, comment_text, comment_id) abort
	let comment_id = ""
	let request = "POST"
	if a:comment_id > 0
		let comment_id = "/" . a:comment_id
		let request = "PUT"
	endif

	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key . "/comment" . comment_id,
		\ "--request", request,
		\ "--data", json_encode({"body": a:comment_text}),
	\ )
endfunction

function api#link_issue(callback, outward_key, inward_key, type_name) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issueLink",
		\ "--data", json_encode({
			\ "outwardIssue": {"key": a:outward_key},
			\ "inwardIssue": {"key": a:inward_key},
			\ "type": {"name": a:type_name},
		\ })
	\ )
endfunction

function api#assign_issue_to_epic(callback, key, epic_id) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ s:agile_url . "/epic/" . a:epic_id . "/issue",
		\ "--data", json_encode({"issues": [a:key]}),
	\ )
endfunction
