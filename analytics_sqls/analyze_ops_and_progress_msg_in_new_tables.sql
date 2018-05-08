-- #Merges two data sets in a single table
INSERT INTO operation2
select * from operation
    where not exists(
            select * from operation2 
                 where operation.process_id=process_id
                     )

INSERT INTO progress_message2
select * from progress_message
    where not exists(
            select * from progress_message2 
                 where progress_message.process_id=progress_message2.process_id
                     )

--how many test deploymetns occurred 
select count(*) from operation2 where mta_id = 'anatz'

drop table public.operation
drop table progress_message
drop table result
alter table operation2 rename to operation
alter table progress_message2 rename to progress_message

-- lsit execution time for each operation
select process_id, process_type, mta_id, EXTRACT(EPOCH FROM (ended_at - started_at)) from operation

--Average operation time per type

select process_type, mta_id, AVG(T.optime)/60 as avg_time, COUNT(*) as ops_count
  FROM (
    SELECT  process_type, mta_id , EXTRACT(EPOCH FROM (ended_at - started_at)) as optime 
    FROM operation 
    WHERE final_state = 'FINISHED' AND process_type = 'BLUE_GREEN_DEPLOY'
  ) as T 
GROUP BY process_type, mta_id
ORDER BY avg_time ASC 

select process_type, mta_id, AVG(T.optime)/60 as avg_time, COUNT(*) as ops_count
  FROM (
    SELECT  process_type, mta_id , EXTRACT(EPOCH FROM (ended_at - started_at)) as optime 
    FROM operation 
    WHERE final_state = 'FINISHED' AND process_type = 'DEPLOY'
  ) as T 
GROUP BY process_type, mta_id
ORDER BY avg_time ASC 

select process_type, mta_id, AVG(T.optime)/60 as avg_time, COUNT(*) as ops_count
  FROM (
    SELECT  process_type, mta_id , EXTRACT(EPOCH FROM (ended_at - started_at)) as optime 
    FROM operation 
    WHERE final_state = 'FINISHED' AND process_type = 'UNDEPLOY'
  ) as T 
GROUP BY process_type, mta_id
ORDER BY avg_time ASC 

-- The following creates a temporary table called 'result', which will hold a row for each failed process along with it's error message
CREATE table result AS
SELECT operation.process_id, process_type, mta_id, progress_message.text, progress_message.task_id,  progress_message.timestamp 
FROM operation
LEFT JOIN  progress_message
ON progress_message.process_id = operation.process_id
WHERE operation.final_state = 'ABORTED' AND progress_message.text is not null AND progress_message.type = 'ERROR'
AND progress_message.id IN
(SELECT MIN(id)
 FROM progress_message
 WHERE progress_message.type = 'ERROR'
 GROUP BY progress_message.process_id
)
ORDER BY operation.started_at;

-- The following function, counts and deletes the processes from such a result table, which have failed with a matching error message
CREATE OR REPLACE FUNCTION countProcessErrors ( table_name text, regex text, target_table_name text)
    RETURNS void AS
$$
DECLARE
    resultstr text;
    selectsql text;
BEGIN
    selectsql := 'select count(*) from '||table_name||' where text  ~ '''||regex||'''';
    RAISE notice 'sql %', selectsql;
    EXECUTE selectsql INTO resultstr ;
    RAISE notice 'result: %',resultstr;
    EXECUTE('insert into '||target_table_name||' select * from '||table_name||' where text  ~ '''||regex||'''' );
    EXECUTE('delete from '||table_name||' where text  ~ '''||regex||'''' );
END;
$$
LANGUAGE plpgsql;


-- A copy of the result table could be used for the analysis to prevent data loss in case of incident deletes:
drop table result_wip;
create table result_wip as
select * from result;
drop table ds_errors;
create table ds_errors as select * from result_wip LIMIT 0;
-- Count errors caused by deploy-service app known issues: 
select countProcessErrors('result_wip','.*has expired.*$','ds_errors');
select countProcessErrors('result_wip','.*Process was aborted.*$','ds_errors');
select countProcessErrors('result_wip','.*Execution of step .* has timed out.*$','ds_errors');
select countProcessErrors('result_wip','.*401 Unauthorized: Invalid Auth Token.*$','ds_errors');
select countProcessErrors('result_wip','.*while trying to invoke the method .* of a null object loaded from local variable.*$','ds_errors');
select countProcessErrors('result_wip','.* 400 Bad Request: The app package is invalid: bits have not been uploaded.*$','ds_errors');
select countProcessErrors('result_wip','Error creating service brokers.*502 Bad Gateway: The service broker rejected the request to .*-idle.cfapps.*404 Not Found: Requested route .* does not exist.*$','ds_errors');
-- Count errors caused by invalid MTA content or environment limits enforcements:
drop table mta_errors_deployment_to_container;
create table mta_errors_deployment_to_container as select * from result_wip LIMIT 0;
select countProcessErrors('result_wip','.*Error starting application .*: Some instances have crashed. Check the logs of your application for more information.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Unresolved MTA modules .*, these modules are neither part of MTA archive, nor already deployed.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error while parsing YAML string:.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Deployment to container .* failed.*$','mta_errors_deployment_to_container', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Unable to resolve.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*You have exceeded your organization''s memory limit.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Application with xsappname .* already exists.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','Application .*" exists and is associated with MTA.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Service broker error: Error updating application .* \(Cannot change AppId with update.\).*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error building cloud model: Invalid type for key .*, expected .* but got .*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*No parameter provided. Parameter is mandatory.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Service plan .* for service .* not found.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Could noy bind application .* to service .*: 404 NotFound: Service .* not found.*$', 'mta_errors_deployment_to_container', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*higher version of your MTA is already deployed.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Service .* already exists, but is associated with MTA.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','Error .* application .* Could not bind application .* to service .* 404 Not Found: Service.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error processing MTA archive: Conflicting process .* found for MTA.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error executing application .*: Deployment of .* content .*failed \[Deployment Id: deploy-\d*\].*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error merging descriptors:.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error resolving merged descriptor properties and parameters.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error detecting MTA major schema version: Versions .* and .* are incompatible.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Please delete the service_bindings, service_keys, and routes associations for your service_instances.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*400 Bad Request: The service does not support changing plans.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*400 Bad Request: You have exceeded the instance limit for your .*s quota.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*400 Bad Request: You have exceeded the total routes for your organization.s quota.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.* 404 Not Found: Could not create service instance .* Service plan .* from service offering .* was not found.$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*Error starting application .* 404 Not Found: Application .* not found.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','.*403 Forbidden: A service instance for the selected plan cannot be created in this organization. The plan is visible because another organization you belong to has access to it.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','Error detecting deployed MTA: 404 Not Found: The app could not be found: .*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','Error detecting deployed MTA:.* 404 Not Found: The service instance could not be found:.*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','Error uploading application .*ContentException: Cannot find archive entry .*$', 'mta_errors_deployment_to_container');
select countProcessErrors('result_wip','Error adding domains: Controller operation failed: 403 Forbidden: You are not authorized to perform the requested action.*$', 'mta_errors_deployment_to_container');
-- Count errors caused by service-broker malfunctions

select distinct text from borker_errors;
drop table borker_errors;
create table borker_errors as 
select * from result_wip LIMIT 0;
select countProcessErrors('result_wip','.*Service broker error: Error updating application null.*$','borker_errors');
select countProcessErrors('result_wip','.*502 Bad Gateway: Service broker error..*$','borker_errors');
select countProcessErrors('result_wip','.*The service broker returned an invalid response for the request to.*$','borker_errors');
select countProcessErrors('result_wip','.*400 Bad Request: .* service broker .*$','borker_errors');
select countProcessErrors('result_wip','.*502 Bad Gateway: .*hdi*$','borker_errors');
                                          
select countProcessErrors('result_wip','.*504 Gateway Timeout: The request to the service broker timed out: .*internal-xsuaa.authentication.sap.hana.ondemand.com.*$','borker_errors');                                          
select countProcessErrors('result_wip','.*502 Bad Gateway: The service broker rejected the request to .*abacus-broker.cf.sap.hana.ondemand.com.*$','borker_errors');
select countProcessErrors('result_wip','.*502 Bad Gateway: Service instance .* The service broker rejected the request to \(hana-broker\.cfapps.* 404 Not Found .*Requested route .* does not exist.*$','borker_errors');
select countProcessErrors('result_wip','.*could not be created because all attempt\(s\) to use service offerings .*hana.* failed.*$','borker_errors');


select distinct text from borker_errors
-- Count errors caused by cloud controller malfunctions
drop table controller_errors_500;
create table controller_errors_500 as select * from result_wip LIMIT 0;
drop table controller_errors_stopped;
create table controller_errors_stopped as select * from result_wip LIMIT 0;
drop table controller_errors_404;
create table controller_errors_404 as select * from result_wip LIMIT 0;
drop table controller_errors_task;
create table controller_errors_task as select * from result_wip LIMIT 0;
select countProcessErrors('result_wip','.*Controller operation failed: 500 Unable to find required element.*$','controller_errors_500');
drop table controller_errors_stopped;
create table controller_errors_stopped as select * from result_wip LIMIT 0;
select countProcessErrors('result_wip','.*Could not fetch stats for stopped app:.*$','controller_errors_stopped');
drop table controller_errors_task;
create table controller_errors_task as select * from result_wip LIMIT 0;
select countProcessErrors('result_wip','.*Controller operation failed: .* Task cannot be accepted.*$','controller_errors_task');
drop table controller_errors_404;
create table controller_errors_404 as select * from result_wip LIMIT 0;
select countProcessErrors('result_wip','.*Controller operation failed: 404 Not Found.*$','controller_errors_404');


