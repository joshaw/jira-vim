" https://developer.atlassian.com/cloud/jira/platform/rest/v2/
" https://docs.atlassian.com/jira-software/REST/7.3.1/#agile/1.0/

augroup Jira
	autocmd!
	autocmd BufReadCmd jira://* :call issue_view#read_cmd(expand('<afile>'))
	autocmd BufWriteCmd jira://* :call issue_view#post_comment(b:jira_issue.key)
augroup END

"nnoremap <silent> <tab> :wincmd w<CR>
nnoremap <silent> R :unlet! b:jira_comment_id <bar> call issue_view#reload(utils#get_key())<CR>
nnoremap <silent> gx :call system(["xdg-open", utils#get_issue_url(utils#get_key())])<CR>
nnoremap <silent> zv :call issue_view#toggle(utils#get_key())<CR>

command! -nargs=0 JiraToggleIssueView :call issue_view#toggle(utils#get_key())
command! -nargs=* Jira :call Jira(<q-args>)

function Jira(...) abort
	" List Window
	let list_buf = list_view#the()
	let list_win = win_findbuf(list_buf)
	if empty(list_win)
		let list_win = [win_getid()]
		execute "buffer " . list_buf
	else
		call win_gotoid(list_win[0])
	endif
	let g:jira_list_win = win_getid()
	call list_view#setup()

	" Determine query to use
	if empty(a:000) || empty(a:1)
		let query = utils#get_saved_queries().default
	elseif has_key(utils#get_saved_queries(), a:1)
		let query = utils#get_saved_queries()[a:1]
	elseif a:1 =~# '^\u\+-\d\+$'
		let query = "key = " . a:1
		call issue_view#load_previous_window(a:1)
	else
		let query = a:1
	endif

	if get(g:, "jira_open_issue_view_by_default", 0)
		call issue_view#toggle("summary")
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
		let g:jira_query_data = a:data
		let summary_buf = bufnr("jira://summary")
		if summary_buf > 0 && ! empty(win_findbuf(summary_buf))
			call issue_view#set_summary(a:data, summary_buf)
		endif
	endfunction

	call api#search({d -> s:search_callback(d)}, query)
endfunction
