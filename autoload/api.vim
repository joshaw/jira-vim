" Jira API functions ------------------------
function s:jira_curl(callback, url, ...) abort
	if a:url =~? '^https\?://'
		let full_url = a:url
	else
		let full_url = utils#get_atlassian_url() . a:url
	endif

	let full_cmd = [
		\ "curl",
		\ "--header", "Content-Type: application/json",
		\ "--header", "Accept: application/json",
		\ "--compressed",
		\ "--max-time", "20",
		\ "--silent",
		\ "--show-error",
		\ "--stderr", "-",
	\ ] + [full_url] + a:000

	let username = utils#get_username()
	let password = utils#get_password()
	if !empty(username) && !empty(password)
		let user_flag = username . ":" . password
		call insert(full_cmd, "--user", 1)
		call insert(full_cmd, user_flag, 2)
	endif

	let a:callback.stdout_buffered = 1
	let jobid = jobstart(full_cmd, a:callback)

	if jobid < 0
		echoerr "Executable not found, " . full_cmd[0]
	endif
	return jobid
endfunction

function s:try_to_decode_json(data) abort
	try
		return json_decode(a:data)
	catch
		return a:data
	endtry
endfunction

function s:jira_curl_json(callback, url, ...) abort
	return call("s:jira_curl", [
		\ {"on_stdout": {j, data, e -> call(a:callback, [s:try_to_decode_json(data)])}},
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
		\ || getftime(file_path) < localtime() - get(g:, "jira_cache_timeout", 60*60*2)
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
	return s:jira_curl_json(a:callback, "/myself?expand=groups,applicationRoles")
endfunction

function api#search(callback, query, options) abort
	let full_query = json_encode({
		\ "jql": a:query,
		\ "maxResults": get(g:, "jira_search_max_results", 100),
		\ "startAt": get(a:options, "start_at", 0),
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
		\ "components",
		\ "created",
		\ "creator",
		\ "customfield_10005",
		\ "customfield_12055",
		\ "description",
		\ "fixVersions",
		\ "issuelinks",
		\ "issuetype",
		\ "parent",
		\ "reporter",
		\ "status",
		\ "summary",
		\ "updated",
		\ "versions",
		\ "watches",
	\ ], ",")

	let expand = join(["changelog", "transitions"], ",")

	let url = "/issue/" . a:key . "?fields=" . fields . "&expand=" . expand

	function! s:set_epic_issues(callback, issue, search_results) abort
		let a:issue.fields.epic_issues = []
		for issue in a:search_results.issues
			" Copy specific elements to reduce size of cache object
			call add(a:issue.fields.epic_issues, {
				\ "key": issue.key,
				\ "fields": {
					\ "summary": issue.fields.summary,
					\ "status": {
						\ "name": issue.fields.status.name,
						\ "category": issue.fields.status.statusCategory.name,
					\ },
				\ },
			\ })
		endfor
		let fname = utils#cache_file(a:issue.key . ".json")
		call s:write_cache_and_callback(a:callback, fname, a:issue)
	endfunction

	function! s:process_issue(callback, issue) abort
		if !utils#issue_is_valid(a:issue)
			call call(a:callback, [a:issue])
			return
		endif

		if a:issue.fields.issuetype.name ==? "epic" && !has_key(a:issue.fields, "epic_issues")
			call api#search(
				\ {epic_issues -> s:set_epic_issues(a:callback, a:issue, epic_issues)},
				\ '"epic link" = ' . a:issue.key,
				\ {},
			\ )
		else
			call call(a:callback, [a:issue])
		endif
	endfunction

	return s:curl_cache(
		\ {issue -> s:process_issue(a:callback, issue)},
		\ url,
		\ a:key . ".json",
		\ a:reload
	\ )
endfunction

function api#get_boards(callback) abort
	return s:curl_cache(a:callback, utils#get_agile_url() . "/board", "boards.json", 0)
endfunction

function api#get_projects(callback) abort
	let params = "?maxResults=50&orderBy=lastIssueUpdatedTime&expand=lead"
	let url = "/project/search" . params
	let fname = "projects.json"
	call s:curl_cache(a:callback, url, fname, 0)
endfunction

function api#get_sprints(callback, board_id) abort
	let url = utils#get_agile_url() . "/board/" . a:board_id . "/sprint?state=future,active"
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
	let url = utils#get_agile_url() . "/board/" . a:board_id . "/epic"
	let fname = "epics-" . a:board_id . ".json"
	call s:curl_cache(a:callback, url, fname, 0)
endfunction

function api#get_transitions(callback, key) abort
	call s:jira_curl_json(a:callback, "/issue/" . a:key . "/transitions")
endfunction

function api#get_users() abort
	function! s:format_users(users) abort
		if type(a:users) != v:t_list
			return
		endif
		let users_dict = {}
		for u in a:users
			if u.accountType == "customer" || u.accountType == "app"
				continue
			endif
			if !u.active
				let u.displayName = "~" . u.displayName
			endif
			let users_dict[u.accountId] = u.displayName
		endfor
		let fname = utils#cache_file("users.json")
		call writefile([json_encode(users_dict)], fname)
	endfunction
	call s:jira_curl_json({users -> s:format_users(users)}, "/users/search?maxResults=1000")
endfunction

function api#get_versions(callback, project) abort
	let url = "/project/" . a:project . "/versions"
	let fname = "versions-" . a:project . ".json"
	call s:curl_cache(a:callback, url, fname, 0)
endfunction

function api#get_components(callback, project) abort
	let url = "/project/" . a:project . "/components"
	let fname = "components-" . a:project . ".json"
	call s:curl_cache(a:callback, url, fname, 0)
endfunction

" PUT functions

function api#claim_issue(callback, key) abort
	return s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key . "/assignee",
		\ "--request", "PUT",
		\ "--data", json_encode({"accountId": utils#get_account_id()}),
	\ )
endfunction

function s:edit_issue(callback, key, data) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue/" . a:key,
		\ "--request", "PUT",
		\ "--data", json_encode(a:data),
	\ )
endfunction

function api#assign_issue_to_sprint(callback, key, sprint_id) abort
	call s:edit_issue(a:callback, a:key, {
		\ "update": {"customfield_10005": [{"set": a:sprint_id}]}
	\ })
endfunction

function api#set_issue_summary(callback, key, new_summary) abort
	call s:edit_issue(a:callback, a:key, {
		\ "update": {"summary": [{"set": a:new_summary}]}
	\ })
endfunction

function api#set_issue_type(callback, key, new_type) abort
	call s:edit_issue(a:callback, a:key, {
		\ "fields": {"issuetype": {"id": a:new_type}}
	\ })
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
		\ utils#get_agile_url() . "/epic/" . a:epic_id . "/issue",
		\ "--data", json_encode({"issues": [a:key]}),
	\ )
endfunction

function api#create_issue(callback, data) abort
	call s:jira_curl(
		\ {"on_exit": {j, d, e -> d == 0 && call(a:callback, [])}},
		\ "/issue",
		\ "--data", json_encode({"fields": a:data}),
	\ )
endfunction
