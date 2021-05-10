" https://developer.atlassian.com/cloud/jira/platform/rest/v2/
" https://docs.atlassian.com/jira-software/REST/7.3.1/#agile/1.0/

let b:cached_line = -1

let g:jira_list_buffer = -1
let g:jira_issue_buffer = -1

augroup Jira
	autocmd!
	autocmd BufReadCmd jira://* :call issue_view#read_cmd(expand('<afile>'))
augroup END

"nnoremap <silent> <tab> :wincmd w<CR>
nnoremap q :qa!<CR>

function Jira(...) abort
	" List Window
	let g:jira_list_buffer = bufadd("jira-list-view")
	let list_win = win_findbuf(g:jira_list_buffer)
	if empty(list_win)
		let list_win = [win_getid()]
		execute "buffer " . g:jira_list_buffer
	else
		call win_gotoid(list_win[0])
	endif
	let g:jira_list_win = winnr()
	call list_view#setup()

	" Issue Window
	let g:jira_issue_buffer = bufadd("jria-issue-view")
	let issue_win = win_findbuf(g:jira_issue_buffer)
	if empty(issue_win)
		call issue_view#open()
	else
		call win_gotoid(issue_win[0])
	endif
	let g:jira_issue_win = winnr()
	call issue_view#setup()

	" Back to List Window
	call win_gotoid(list_win[0])

	if empty(a:000) || empty(a:1)
		let query = utils#get_saved_queries().mysprint
	elseif has_key(utils#get_saved_queries(), a:1)
		let query = utils#get_saved_queries()[a:1]
	elseif a:1 =~# '^\u\+-\d\+$'
		let query = "key = " . a:1
		call issue_view#load(a:1, {})
		call list_view#set(query, [])
		return
	else
		let query = a:1
	endif

	function! s:search_callback(data) abort closure
		if has_key(a:data, "errorMessages")
			let fmt_list = a:data.errorMessages
		elseif has_key(a:data, "issues")
			let fmt_list = list_view#format(a:data.issues)
			call list_view#setup_highlighting(fmt_list[0])
			let fmt_list = fmt_list[1:]
		else
			echoerr "Could not understand response"
		endif

		call list_view#set(query, fmt_list)
	endfunction

	call api#search({d -> s:search_callback(d)}, query)
endfunction
